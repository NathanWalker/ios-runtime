//
//  ObjCClassBuilder.mm
//  NativeScript
//
//  Created by Jason Zhekov on 9/8/14.
//  Copyright (c) 2014 Telerik. All rights reserved.
//

#include "ObjCClassBuilder.h"
#include "./TNSDerivedClassProtocol.h"
#include "FFIType.h"
#include "Interop.h"
#include "Metadata.h"
#include "ObjCConstructorDerived.h"
#include "ObjCConstructorNative.h"
#include "ObjCMethodCallback.h"
#include "ObjCProtocolWrapper.h"
#include "ObjCPrototype.h"
#include "ObjCSuperObject.h"
#include "ObjCTypes.h"
#include "ObjCWrapperObject.h"
#include "TNSFastEnumerationAdapter.h"
#include "TNSRuntime+Private.h"
#include "TypeFactory.h"
#include <sstream>

namespace NativeScript {
using namespace JSC;
using namespace Metadata;

static WTF::CString computeRuntimeAvailableClassName(const char* userDesiredName) {
    WTF::CString runtimeAvailableName(userDesiredName);

    for (int i = 1; objc_getClass(runtimeAvailableName.data()); ++i) {
        runtimeAvailableName = WTF::String::format("%s%d", userDesiredName, i).utf8();
    }

    return runtimeAvailableName;
}

static IMP findNotOverridenMethod(Class klass, SEL method) {
    while (class_conformsToProtocol(klass, @protocol(TNSDerivedClass))) {
        klass = class_getSuperclass(klass);
    }

    return class_getMethodImplementation(klass, method);
}

static void attachDerivedMachinery(GlobalObject* globalObject, Class newKlass, JSValue superPrototype) {
    /// In general, this method swizzles the following methods on the newly created class:
    /// 1. allocWithZone - called by alloc()
    /// 2. retain - called by the ObjC runtime when someone references the object
    /// 3. release - called by the ObjC runtime when the object is unreferenced by someone
    /// The purpose of this is to synchronize the lifetime of the JavaScript instances and their native counterparts.
    /// That is to make sure that a JavaScript object exists as long as its native counterpart does and vice-versa.

    __block Class metaClass = object_getClass(newKlass);

    __block Class blockKlass = newKlass;
    IMP allocWithZone = findNotOverridenMethod(metaClass, @selector(allocWithZone:));
    IMP newAllocWithZone = imp_implementationWithBlock(^(id self, NSZone* nsZone) {
      id instance = allocWithZone(self, @selector(allocWithZone:), nsZone);
      VM& vm = globalObject->vm();
      JSLockHolder lockHolder(vm);

      Structure* instancesStructure = globalObject->constructorFor(blockKlass, ProtocolMetas())->instancesStructure();
      auto derivedWrapper = ObjCWrapperObject::create(vm, instancesStructure, instance, globalObject);

      Structure* superStructure = ObjCSuperObject::createStructure(vm, globalObject, superPrototype);
      auto superObject = ObjCSuperObject::create(vm, superStructure, derivedWrapper.get(), globalObject);
      derivedWrapper->putDirect(vm, vm.propertyNames->superKeyword, superObject.get(), PropertyAttribute::ReadOnly | PropertyAttribute::DontEnum | PropertyAttribute::DontDelete);

      return instance;
    });
    class_addMethod(metaClass, @selector(allocWithZone:), newAllocWithZone, "@@:");

    /// We swizzle the retain and release methods for the following reason:
    /// When we instantiate a native class via a JavaScript call we add it to the object map thus
    /// incrementing the retainCount to 1. Then, when the native object is referenced somewhere else its count will become more than 1.
    /// Since we want to keep the corresponding JavaScript object alive even if it is not used anywhere, we call gcProtect on it.
    /// Whenever the native object is released so that its retainCount is 1 (the object map), we unprotect the corresponding JavaScript object
    /// in order to make both of them destroyable/GC-able. When the JavaScript object is GC-ed we release the native counterpart as well.
    IMP retain = findNotOverridenMethod(newKlass, @selector(retain));
    IMP newRetain = imp_implementationWithBlock(^(id self) {
      if ([self retainCount] == 1) {
          if (auto runtime = [TNSRuntime runtimeForVM:&globalObject->vm()]) {
              if (JSObject* object = runtime->_objectMap.get()->get(self)) {
                  JSLockHolder lockHolder(globalObject->vm());
                  /// TODO: This gcProtect() call might render the same call in the allocWithZone override unnecessary. Check if this is true.
                  gcProtect(object);
              }
          }
      }

      return retain(self, @selector(retain));
    });
    class_addMethod(newKlass, @selector(retain), newRetain, "@@:");

    void (*release)(id, SEL) = (void (*)(id, SEL))findNotOverridenMethod(newKlass, @selector(release));
    IMP newRelease = imp_implementationWithBlock(^(id self) {
      if ([self retainCount] == 2) {
          if (auto runtime = [TNSRuntime runtimeForVM:&globalObject->vm()]) {
              if (JSObject* object = runtime->_objectMap.get()->get(self)) {
                  JSLockHolder lockHolder(globalObject->vm());
                  gcUnprotect(object);
              }
          }
      }

      release(self, @selector(release));
    });
    class_addMethod(newKlass, @selector(release), newRelease, "v@:");
}

static bool isValidType(ExecState* execState, JSValue& value) {
    JSC::VM& vm = execState->vm();
    const FFITypeMethodTable* table;
    if (!tryGetFFITypeMethodTable(vm, value, &table)) {
        return false;
    }
    return true;
}

static void addMethodToClass(ExecState* execState, Class klass, JSCell* method, SEL methodName, JSValue& typeEncoding) {
    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
    JSC::VM& vm = execState->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    CallData callData;
    if (method->methodTable(vm)->getCallData(method, callData) == CallType::None) {
        WTF::String message = WTF::String::format("Method %s is not a function.", sel_getName(methodName));
        scope.throwException(execState, createError(execState, method, message, defaultSourceAppender));
        return;
    }
    if (!typeEncoding.isObject()) {
        WTF::String message = WTF::String::format("Method %s has an invalid type encoding", sel_getName(methodName));
        scope.throwException(execState, createError(execState, method, message, defaultSourceAppender));
        return;
    }

    JSObject* typeEncodingObj = asObject(typeEncoding);
    PropertyName returnsProp = Identifier::fromString(execState, "returns");
    if (!typeEncodingObj->hasOwnProperty(execState, returnsProp)) {
        WTF::String message = WTF::String::format("Method %s is missing its return type encoding", sel_getName(methodName));
        scope.throwException(execState, createError(execState, typeEncodingObj, message, defaultSourceAppender));
        return;
    }

    std::stringstream compilerEncoding;

    JSValue returnTypeValue = typeEncodingObj->get(execState, returnsProp);
    if (scope.exception()) {
        return;
    } else if (!isValidType(execState, returnTypeValue)) {
        WTF::String message = WTF::String::format("Method %s has an invalid return type encoding", sel_getName(methodName));
        scope.throwException(execState, createError(execState, returnTypeValue, message, defaultSourceAppender));
        return;
    }

    compilerEncoding << getCompilerEncoding(vm, returnTypeValue.asCell());
    compilerEncoding << "@:"; // id self, SEL _cmd

    JSValue parameterTypesValue = typeEncodingObj->get(execState, Identifier::fromString(execState, "params"));
    if (scope.exception()) {
        return;
    }

    WTF::Vector<Strong<JSCell>> parameterTypesCells;
    JSArray* parameterTypesArr = jsDynamicCast<JSArray*>(vm, parameterTypesValue);
    if (parameterTypesArr == nullptr && !parameterTypesValue.isUndefinedOrNull()) {
        WTF::String message = WTF::String::format("The 'params' property of method %s is not an array", sel_getName(methodName));
        scope.throwException(execState, createError(execState, parameterTypesValue, message, defaultSourceAppender));
        return;
    }

    if (parameterTypesArr) {
        for (unsigned int i = 0; i < parameterTypesArr->length(); ++i) {
            JSValue parameterType = parameterTypesArr->get(execState, i);
            if (scope.exception()) {
                return;
            } else if (!isValidType(execState, parameterType)) {
                WTF::String message = WTF::String::format("Method %s has an invalid type encoding for argument %d", sel_getName(methodName), i + 1);
                scope.throwException(execState, createError(execState, parameterType, message, defaultSourceAppender));
                return;
            }

            parameterTypesCells.append(Strong<JSCell>(vm, parameterType.asCell()));
            compilerEncoding << getCompilerEncoding(vm, parameterType.asCell());
        }
    }

    auto callback = ObjCMethodCallback::create(execState->vm(), globalObject, globalObject->objCMethodCallbackStructure(), method, returnTypeValue.asCell(), parameterTypesCells);
    gcProtect(callback.get());
    if (!class_addMethod(klass, methodName, reinterpret_cast<IMP>(callback->functionPointer()), compilerEncoding.str().c_str())) {
        WTFCrash();
    }
}

ObjCClassBuilder::ObjCClassBuilder(ExecState* execState, JSValue baseConstructor, JSObject* prototype, const WTF::String& className) {
    // TODO: Inherit from derived constructor.
    VM& vm = execState->vm();
    if (!baseConstructor.inherits(vm, ObjCConstructorNative::info())) {
        auto scope = DECLARE_THROW_SCOPE(vm);

        scope.throwException(execState, createError(execState, "Extends is supported only for native classes."_s, defaultSourceAppender));
        return;
    }

    this->_baseConstructor = Strong<ObjCConstructorNative>(execState->vm(), jsCast<ObjCConstructorNative*>(baseConstructor));

    WTF::CString runtimeName = computeRuntimeAvailableClassName(className.isEmpty() ? this->_baseConstructor->metadata()->name() : className.utf8().data());
    Class klass = objc_allocateClassPair(this->_baseConstructor->klasses().known, runtimeName.data(), 0);
    objc_registerClassPair(klass);

    if (!className.isEmpty() && runtimeName != className.utf8()) {
        warn(execState, WTF::String::format("Objective-C class name \"%s\" is already in use - using \"%s\" instead.", className.utf8().data(), runtimeName.data()));
    }

    class_addProtocol(klass, @protocol(TNSDerivedClass));
    class_addProtocol(object_getClass(klass), @protocol(TNSDerivedClass));

    JSValue basePrototype = this->_baseConstructor->get(execState, execState->vm().propertyNames->prototype);
    prototype->setPrototypeDirect(execState->vm(), basePrototype);

    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
    Structure* structure = ObjCConstructorDerived::createStructure(execState->vm(), globalObject, this->_baseConstructor.get());
    auto derivedConstructor = ObjCConstructorDerived::create(execState->vm(), globalObject, structure, prototype, klass);

    prototype->putDirect(execState->vm(), execState->vm().propertyNames->constructor, derivedConstructor.get(), static_cast<unsigned>(PropertyAttribute::DontEnum));

    this->_constructor = derivedConstructor;
}

void ObjCClassBuilder::implementProtocol(ExecState* execState, JSValue protocolWrapper) {
    VM& vm = execState->vm();
    if (!protocolWrapper.inherits(vm, ObjCProtocolWrapper::info())) {
        auto scope = DECLARE_THROW_SCOPE(vm);

        scope.throwException(execState, createError(execState, protocolWrapper, "is not a protocol object."_s, defaultSourceAppender));
        return;
    }

    ObjCProtocolWrapper* protocolWrapperObject = jsCast<ObjCProtocolWrapper*>(protocolWrapper);

    this->_protocols.append(protocolWrapperObject->metadata());

    if (Protocol* aProtocol = protocolWrapperObject->protocol()) {
        Class klass = this->klass();
        if ([klass conformsToProtocol:aProtocol]) {
            WTF::String errorMessage = WTF::String::format("Class \"%s\" already implements the \"%s\" protocol.", class_getName(klass), protocol_getName(aProtocol));
            warn(execState, errorMessage);
        } else {
            class_addProtocol(klass, aProtocol);
            class_addProtocol(object_getClass(klass), aProtocol);
        }
    }
}

void ObjCClassBuilder::implementProtocols(ExecState* execState, JSValue protocolsArray) {
    if (protocolsArray.isUndefinedOrNull()) {
        return;
    }

    JSC::VM& vm = execState->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!protocolsArray.inherits(vm, JSArray::info())) {
        scope.throwException(execState, createError(execState, protocolsArray, "the 'protocols' property is not an array"_s, defaultSourceAppender));
        return;
    }

    uint32_t length = protocolsArray.get(execState, execState->vm().propertyNames->length).toUInt32(execState);
    for (uint32_t i = 0; i < length; i++) {
        JSValue protocolWrapper = protocolsArray.get(execState, i);
        this->implementProtocol(execState, protocolWrapper);

        if (scope.exception()) {
            return;
        }
    }
}

void ObjCClassBuilder::addInstanceMethod(ExecState* execState, const Identifier& jsName, JSCell* method) {
    JSValue basePrototype = this->_constructor->get(execState, execState->vm().propertyNames->prototype)
                                .toObject(execState)
                                ->getPrototypeDirect(execState->vm());

    overrideObjcMethodCalls(execState,
                            basePrototype.toObject(execState),
                            jsName,
                            method,
                            this->_constructor->metadata(),
                            MemberType::InstanceMethod,
                            this->klass(),
                            this->_protocols);
}

void ObjCClassBuilder::addInstanceMethod(ExecState* execState, const Identifier& jsName, JSCell* method, JSC::JSValue& typeEncoding) {
    SEL methodName = sel_registerName(jsName.utf8().data());
    addMethodToClass(execState, this->klass(), method, methodName, typeEncoding);
}

void ObjCClassBuilder::addProperty(ExecState* execState, const Identifier& name, const PropertyDescriptor& propertyDescriptor) {
    RELEASE_ASSERT(propertyDescriptor.isAccessorDescriptor());

    WTF::StringImpl* propertyName = name.impl();
    const PropertyMeta* propertyMeta = this->_baseConstructor->metadata()->deepInstanceProperty(propertyName, KnownUnknownClassPair(), /*includeProtocols*/ true, this->_protocols);

    if (propertyMeta != nullptr && (!propertyMeta->hasGetter() || !propertyMeta->hasSetter())) {
        // property found but it's missing a getter or setter. Check whether its hiding a base class with both
        const PropertyMeta* propertyMetaNoProtocols = this->_baseConstructor->metadata()->deepInstanceProperty(propertyName, KnownUnknownClassPair(), /*includeProtocols*/ false, this->_protocols);
        if (propertyMetaNoProtocols && propertyMetaNoProtocols->hasGetter() && propertyMetaNoProtocols->hasSetter()) {
            // Take base class property meta which contains both getter and setter
            propertyMeta = propertyMetaNoProtocols;
        }
    }

    VM& vm = execState->vm();
    if (!propertyMeta) {
        JSValue basePrototype = this->_constructor->get(execState, execState->vm().propertyNames->prototype)
                                    .toObject(execState)
                                    ->getPrototypeDirect(execState->vm());
        PropertySlot baseSlot(basePrototype, PropertySlot::InternalMethodType::Get);
        bool hasBaseSlot = basePrototype.getPropertySlot(execState, name, baseSlot);

        if (hasBaseSlot && !baseSlot.isAccessor()) {
            auto throwScope = DECLARE_THROW_SCOPE(vm);
            WTF::String message = WTF::String::format("Cannot override native method \"%s\" with a property, define it as a JS function instead.",
                                                      propertyName->utf8().data());
            throwException(execState, throwScope, JSC::createError(execState, message, defaultSourceAppender));
            return;
        }
    } else {
        Class klass = this->klass();
        GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (const MethodMeta* getter = propertyMeta->getter()) {
            if (propertyDescriptor.getter().isUndefined()) {
                throwVMError(execState, scope, createError(execState, WTF::String::format("Property \"%s\" requires a getter function.", propertyName->utf8().data())));
                return;
            }

            const TypeEncoding* encodings = getter->encodings()->first();
            auto returnType = globalObject->typeFactory()->parseType(globalObject, encodings, /*isStructMember*/ false);
            auto parameterTypes = globalObject->typeFactory()->parseTypes(globalObject, encodings, getter->encodings()->count - 1, /*isStructMember*/ false);

            auto getterCallback = ObjCMethodCallback::create(vm, globalObject, globalObject->objCMethodCallbackStructure(), propertyDescriptor.getter().asCell(), returnType.get(), parameterTypes);
            gcProtect(getterCallback.get());
            std::string compilerEncoding = getCompilerEncoding(globalObject, getter);
            if (!class_addMethod(klass, getter->selector(), reinterpret_cast<IMP>(getterCallback->functionPointer()), compilerEncoding.c_str())) {
                WTFCrash();
            }
        }

        if (const MethodMeta* setter = propertyMeta->setter()) {
            if (propertyDescriptor.setter().isUndefined()) {
                throwVMError(execState, scope, createError(execState, WTF::String::format("Property \"%s\" requires a setter function.", propertyName->utf8().data())));
                return;
            }

            const TypeEncoding* encodings = setter->encodings()->first();
            auto returnType = globalObject->typeFactory()->parseType(globalObject, encodings, /*isStructMember*/ false);
            auto parameterTypes = globalObject->typeFactory()->parseTypes(globalObject, encodings, setter->encodings()->count - 1, /*isStructMember*/ false);

            auto setterCallback = ObjCMethodCallback::create(vm, globalObject, globalObject->objCMethodCallbackStructure(), propertyDescriptor.setter().asCell(), returnType.get(), parameterTypes);
            gcProtect(setterCallback.get());
            std::string compilerEncoding = getCompilerEncoding(globalObject, setter);
            if (!class_addMethod(klass, setter->selector(), reinterpret_cast<IMP>(setterCallback->functionPointer()), compilerEncoding.c_str())) {
                WTFCrash();
            }
        }

        // TODO: class_addProperty
    }
}

void ObjCClassBuilder::addInstanceMembers(ExecState* execState, JSObject* instanceMethods, JSValue exposedMethods) {
    PropertyNameArray prototypeKeys(&execState->vm(), PropertyNameMode::Strings, PrivateSymbolMode::Include);
    JSC::VM& vm = execState->vm();
    instanceMethods->methodTable(vm)->getOwnPropertyNames(instanceMethods, execState, prototypeKeys, EnumerationMode());

    JSValue basePrototype = this->_constructor->get(execState, execState->vm().propertyNames->prototype)
                                .toObject(execState)
                                ->getPrototypeDirect(execState->vm());
    for (Identifier key : prototypeKeys) {
        PropertySlot propertySlot(instanceMethods, PropertySlot::InternalMethodType::GetOwnProperty);

        auto scope = DECLARE_THROW_SCOPE(vm);

        if (!instanceMethods->methodTable(vm)->getOwnPropertySlot(instanceMethods, execState, key, propertySlot)) {
            continue;
        }

        PropertySlot baseSlot(basePrototype, PropertySlot::InternalMethodType::Get);
        bool hasBaseSlot = basePrototype.getPropertySlot(execState, key, baseSlot);
        if (propertySlot.isAccessor()) {
            PropertyDescriptor propertyDescriptor;
            propertyDescriptor.setAccessorDescriptor(propertySlot.getterSetter(), propertySlot.attributes());

            this->addProperty(execState, key, propertyDescriptor);
        } else if (propertySlot.isValue()) {
            JSValue method = propertySlot.getValue(execState, key);

            if (hasBaseSlot) {
                if (baseSlot.isAccessor()) {
                    WTF::String message = WTF::String::format("cannot override native property \"%s\", define it as a JS property instead.",
                                                              key.utf8().data());
                    throwException(execState, scope, JSC::createError(execState, method, message, defaultSourceAppender));
                    return;
                }

                if (!method.isCell()) {
                    WTF::String message = WTF::String::format("cannot override native method \"%s\".",
                                                              key.utf8().data());
                    throwException(execState, scope, JSC::createError(execState, method, message, defaultSourceAppender));
                    return;
                }
            }

            if (method.isCell()) {
                JSValue encodingValue = jsUndefined();
                /// We check here if we have an exposed method for the current instance method.
                /// If we have one we will use its encoding without checking base classes and protocols.
                if (!exposedMethods.isUndefinedOrNull()) {
                    encodingValue = exposedMethods.get(execState, key);
                }
                if (encodingValue.isUndefined()) {
                    this->addInstanceMethod(execState, key, method.asCell());
                } else {
                    this->addInstanceMethod(execState, key, method.asCell(), encodingValue);
                }
            }
        } else {
            WTFCrash();
        }

        if (scope.exception()) {
            return;
        }
    }

    if (exposedMethods.isObject()) {
        PropertyNameArray exposedMethodsKeys(&execState->vm(), PropertyNameMode::Strings, PrivateSymbolMode::Include);
        JSObject* exposedMethodsObject = exposedMethods.toObject(execState);
        exposedMethodsObject->methodTable(vm)->getOwnPropertyNames(exposedMethodsObject, execState, exposedMethodsKeys, EnumerationMode());

        for (Identifier key : exposedMethodsKeys) {
            if (!instanceMethods->hasOwnProperty(execState, key)) {
                WTF::String errorMessage = WTF::String::format("No implementation found for exposed method \"%s\".", key.string().utf8().data());
                warn(execState, errorMessage);
            }
        }
    }

    if (instanceMethods->hasOwnProperty(execState, execState->vm().propertyNames->iteratorSymbol)) {
        auto klass = this->klass();
        class_addProtocol(klass, @protocol(NSFastEnumeration));
        class_addProtocol(object_getClass(klass), @protocol(NSFastEnumeration));

        GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
        IMP imp = imp_implementationWithBlock(^NSUInteger(id self, NSFastEnumerationState* state, id buffer[], NSUInteger length) {
          JSLockHolder lock(globalObject->vm());
          return TNSFastEnumerationAdapter(self, state, buffer, length, globalObject);
        });

        struct objc_method_description fastEnumerationMethodDescription = protocol_getMethodDescription(@protocol(NSFastEnumeration), @selector(countByEnumeratingWithState:objects:count:), YES, YES);
        class_addMethod(klass, @selector(countByEnumeratingWithState:objects:count:), imp, fastEnumerationMethodDescription.types);
    }
}

void ObjCClassBuilder::addStaticMethod(ExecState* execState, const Identifier& jsName, JSCell* method) {

    Class klass = this->klass();
    overrideObjcMethodCalls(execState,
                            this->_constructor.get(),
                            jsName,
                            method,
                            this->_constructor->metadata(),
                            MemberType::StaticMethod,
                            klass,
                            this->_protocols);
}

void ObjCClassBuilder::addStaticMethod(ExecState* execState, const Identifier& jsName, JSCell* method, JSC::JSValue& typeEncoding) {
    Class klass = object_getClass(this->klass());
    SEL methodName = sel_registerName(jsName.utf8().data());
    addMethodToClass(execState, klass, method, methodName, typeEncoding);
}

void ObjCClassBuilder::addStaticMethods(ExecState* execState, JSObject* staticMethods) {
    JSC::VM& vm = execState->vm();
    PropertyNameArray keys(&vm, PropertyNameMode::Strings, PrivateSymbolMode::Include);
    staticMethods->methodTable(vm)->getOwnPropertyNames(staticMethods, execState, keys, EnumerationMode());

    auto scope = DECLARE_THROW_SCOPE(vm);

    for (Identifier key : keys) {
        PropertySlot propertySlot(staticMethods, PropertySlot::InternalMethodType::GetOwnProperty);

        if (!staticMethods->methodTable(vm)->getOwnPropertySlot(staticMethods, execState, key, propertySlot)) {
            continue;
        }

        if (propertySlot.isValue()) {
            JSValue method = propertySlot.getValue(execState, key);
            if (method.isCell()) {
                this->addStaticMethod(execState, key, method.asCell());
            }
        } else {
            WTFCrash();
        }

        if (scope.exception()) {
            return;
        }
    }
}

ObjCConstructorDerived* ObjCClassBuilder::build(ExecState* execState) {
    Class klass = this->klass();

    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());

    globalObject->_objCConstructors.insert({ ConstructorKey(klass), Strong<ObjCConstructorBase>(execState->vm(), this->_constructor.get()) });
    attachDerivedMachinery(globalObject, klass, this->_baseConstructor->get(execState, globalObject->vm().propertyNames->prototype));

    return this->_constructor.get();
}

Class ObjCClassBuilder::klass() {
    return this->_constructor->klasses().known;
}

} //namespace NativeScript
