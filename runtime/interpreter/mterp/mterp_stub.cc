/*
 * Copyright (C) 2015 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "../interpreter_common.h"

/*
 * Stub definitions for targets without mterp implementations.
 */

namespace art {
namespace interpreter {
/*
 * Call this during initialization to verify that the values in asm-constants.h
 * are still correct.
 */
void CheckMterpAsmConstants() {
  // Nothing to check when mterp is not implemented.
}

void InitMterpTls(Thread* self) {
  UNUSED(self);
  UNIMPLEMENTED(FATAL);
  // self->SetMterpDefaultIBase(nullptr);
  // self->SetMterpCurrentIBase(nullptr);
  //self->SetMterpAltIBase(nullptr);
}

bool CanUseMterp() {
  return false;
}

/*
 * The platform-specific implementation must provide this.
 */
extern "C" bool ExecuteMterpImpl(Thread* self,
                                 const uint16_t* dex_instructions,
                                 ShadowFrame* shadow_frame,
                                 JValue* result_register)
    REQUIRES_SHARED(Locks::mutator_lock_) {
  UNUSED(self); UNUSED(shadow_frame); UNUSED(result_register);
  UNUSED(dex_instructions);
  UNIMPLEMENTED(FATAL);
  return false;
}

}  // namespace interpreter
}  // namespace art
