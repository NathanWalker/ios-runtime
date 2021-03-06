//
//  ExtVectorTypeInstance.cpp
//  NativeScript
//
//  Created by Teodor Dermendzhiev on 30/01/2018.
//

#include "ExtVectorTypeInstance.h"
#include "FFISimpleType.h"
#include "IndexedRefInstance.h"
#include "Interop.h"
#include "PointerInstance.h"
#include "RecordConstructor.h"
#include "ReferenceInstance.h"
#include "ReferenceTypeInstance.h"
#include "ffi.h"

namespace NativeScript {
using namespace JSC;
typedef ReferenceTypeInstance Base;

const ClassInfo ExtVectorTypeInstance::s_info = { "ExtVectorTypeInstance", &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(ExtVectorTypeInstance) };

JSValue ExtVectorTypeInstance::read(ExecState* execState, const void* buffer, JSCell* self) {
    ExtVectorTypeInstance* vectorInstance = jsCast<ExtVectorTypeInstance*>(self);
    const size_t size = vectorInstance->_ffiTypeMethodTable.ffiType->size;

    if (!size) {
        return jsNull();
    }

    void* data = malloc(size);
    ASSERT(buffer);
    memcpy(data, buffer, size);

    GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
    ExtVectorTypeInstance* referenceType = jsCast<ExtVectorTypeInstance*>(self);

    PointerInstance* pointer = jsCast<PointerInstance*>(globalObject->interop()->pointerInstanceForPointer(execState, const_cast<void*>(data)));
    pointer->setAdopted(true);
    return IndexedRefInstance::create(execState->vm(), globalObject, globalObject->interop()->extVectorInstanceStructure(), referenceType->innerType(), pointer).get();
}

void ExtVectorTypeInstance::write(ExecState* execState, const JSValue& value, void* buffer, JSCell* self) {
    ExtVectorTypeInstance* referenceType = jsCast<ExtVectorTypeInstance*>(self);

    if (value.isUndefinedOrNull()) {
        memset(buffer, 0, referenceType->ffiTypeMethodTable().ffiType->size);
        return;
    }

    if (IndexedRefInstance* reference = jsDynamicCast<IndexedRefInstance*>(execState->vm(), value)) {
        if (!reference->data()) {
            GlobalObject* globalObject = jsCast<GlobalObject*>(execState->lexicalGlobalObject());
            reference->createBackingStorage(execState->vm(), globalObject, execState, referenceType->innerType());
        }
    }

    bool hasHandle;
    JSC::VM& vm = execState->vm();
    void* handle = tryHandleofValue(vm, value, &hasHandle);
    if (!hasHandle) {
        JSC::VM& vm = execState->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);

        JSValue exception = createError(execState, value, "is not a reference."_s, defaultSourceAppender);
        scope.throwException(execState, exception);
        return;
    }

    memcpy(buffer, handle, referenceType->ffiTypeMethodTable().ffiType->size);
}

const char* ExtVectorTypeInstance::encode(VM& vm, JSCell* cell) {
    ExtVectorTypeInstance* self = jsCast<ExtVectorTypeInstance*>(cell);

    if (!self->_compilerEncoding.empty()) {
        return self->_compilerEncoding.c_str();
    }

    self->_compilerEncoding = "[" + std::to_string(self->_size) + "^";
    const FFITypeMethodTable& table = getFFITypeMethodTable(vm, self->_innerType.get());
    self->_compilerEncoding += table.encode(vm, self->_innerType.get());
    self->_compilerEncoding += "]";
    return self->_compilerEncoding.c_str();
}

void ExtVectorTypeInstance::finishCreation(JSC::VM& vm, JSCell* innerType, bool isStructMember) {
    Base::finishCreation(vm);
    ffi_type* innerFFIType = const_cast<ffi_type*>(getFFITypeMethodTable(vm, innerType).ffiType);

    size_t arraySize = this->_size;

#if defined(__x86_64__)
    // We need isStructMember because double3 vectors are handled
    // differently in x86_64. When a vector is a struct field
    // it is passed in memory but when not - the ST0 register is
    // used for the third element. In armv8 double3 vector will always
    // be passed in memory (as it's size > 16).
    if (this->_size == 3 && isStructMember) {
#else
    // For armv8 we always need to pass the array size
    // as the vector would fill a whole register in order
    // to calculate the proper flags value.
    if (this->_size == 3) {
#endif
        arraySize = 4;
    }

    ffi_type* type = new ffi_type({ .size = arraySize * innerFFIType->size, .alignment = innerFFIType->alignment, .type = FFI_TYPE_EXT_VECTOR });

    type->elements = new ffi_type*[this->_size + 1];

    for (size_t i = 0; i < this->_size; i++) {
        type->elements[i] = innerFFIType;
    }

    type->elements[this->_size] = nullptr;
    this->_extVectorType = type;
    this->_ffiTypeMethodTable.ffiType = type;
    this->_ffiTypeMethodTable.read = &read;
    this->_ffiTypeMethodTable.write = &write;
    this->_ffiTypeMethodTable.encode = &encode;
    this->_ffiTypeMethodTable.canConvert = &canConvert;

    this->_innerType.set(vm, this, innerType);
}

bool ExtVectorTypeInstance::canConvert(ExecState* execState, const JSValue& value, JSCell* buffer) {
    JSC::VM& vm = execState->vm();
    return value.isUndefinedOrNull() || value.inherits(vm, IndexedRefInstance::info()) || value.inherits(vm, PointerInstance::info());
}

void ExtVectorTypeInstance::visitChildren(JSC::JSCell* cell, JSC::SlotVisitor& visitor) {
    Base::visitChildren(cell, visitor);

    ExtVectorTypeInstance* object = jsCast<ExtVectorTypeInstance*>(cell);
    visitor.append(object->_innerType);
}

} // namespace NativeScript
