//
//  JSErrors.h
//  NativeScript
//
//  Created by Jason Zhekov on 2/26/15.
//  Copyright (c) 2015 Telerik. All rights reserved.
//

#ifndef __NativeScript__JSErrors__
#define __NativeScript__JSErrors__

#include <JavaScriptCore/CatchScope.h>
#include <JavaScriptCore/Exception.h>
#include <JavaScriptCore/ScriptCallFrame.h>
#include <JavaScriptCore/ScriptCallStack.h>

#define NS_EXCEPTION_SCOPE_ZERO_RECURSION_KEY @"__nsExceptionScopeZeroRecursion"

#define NS_TRY @try

#define NS_CATCH_THROW_TO_JS(execState)                                                                  \
    @catch (NSException * ex) {                                                                          \
        auto scope = DECLARE_THROW_SCOPE(execState->vm());                                               \
        throwException(execState, scope, JSC::createError(execState, ex.reason, defaultSourceAppender)); \
    }

namespace NativeScript {

void reportErrorIfAny(JSC::ExecState* execState, JSC::CatchScope& scope);
void reportFatalErrorBeforeShutdown(JSC::ExecState*, JSC::Exception*, bool callJsUncaughtErrorCallback = true);
void reportDiscardedError(JSC::ExecState* execState, GlobalObject* globalObject, JSC::Exception* exception);
void dumpExecJsCallStack(JSC::ExecState* execState);
std::string getExecJsCallStack(JSC::ExecState* execState);
std::string dumpJsCallStack(const Inspector::ScriptCallStack& frames);
std::string getCallStack(const Inspector::ScriptCallStack& frames);

} // namespace NativeScript

#endif /* defined(__NativeScript__JSErrors__) */
