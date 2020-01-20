//
//  ReferenceTypeConstructor.cpp
//  NativeScript
//
//  Created by Ivan Buhov on 11/3/14.
//  Copyright (c) 2014 Telerik. All rights reserved.
//

#include "ReferenceTypeConstructor.h"
#include "Interop.h"
#include "JSErrors.h"
#include "PointerInstance.h"
#include "ReferenceTypeInstance.h"
#include "TypeFactory.h"

namespace NativeScript {
using namespace JSC;

const ClassInfo ReferenceTypeConstructor::s_info = { "ReferenceType", &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ReferenceTypeConstructor) };

void ReferenceTypeConstructor::finishCreation(VM& vm, JSObject* referenceTypePrototype) {
    Base::finishCreation(vm, this->classInfo()->className);

    this->putDirectWithoutTransition(vm, vm.propertyNames->prototype, referenceTypePrototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
}

EncodedJSValue JSC_HOST_CALL ReferenceTypeConstructor::constructReferenceType(ExecState* execState) {
    NS_TRY {
        GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());

        JSC::VM& vm = execState->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        if (execState->argumentCount() != 1) {
            return throwVMError(execState, scope, createError(execState, "ReferenceType constructor expects one argument."_s));
        }

        JSValue type = execState->uncheckedArgument(0);
        const FFITypeMethodTable* methodTable;
        if (!tryGetFFITypeMethodTable(vm, type, &methodTable)) {
            return throwVMError(execState, scope, createError(execState, "Not a valid type object is passed as parameter."_s));
        }

        return JSValue::encode(globalObject->typeFactory()->getReferenceType(globalObject, type.asCell()).get());
    }
    NS_CATCH_THROW_TO_JS(execState)

    return JSValue::encode(jsUndefined());
}

} // namespace NativeScript
