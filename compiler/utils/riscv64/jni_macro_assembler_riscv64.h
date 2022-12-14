/*
 * Copyright (C) 2016 The Android Open Source Project
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

#ifndef ART_COMPILER_UTILS_RISCV64_JNI_MACRO_ASSEMBLER_RISCV64_H_
#define ART_COMPILER_UTILS_RISCV64_JNI_MACRO_ASSEMBLER_RISCV64_H_

#include <stdint.h>
#include <memory>
#include <vector>

#include <android-base/logging.h>

#include "assembler_riscv64.h"
#include "base/arena_containers.h"
#include "base/enums.h"
#include "base/macros.h"
#include "offsets.h"
#include "utils/assembler.h"
#include "utils/jni_macro_assembler.h"

namespace art {
namespace riscv64 {

class Riscv64JNIMacroAssembler final : public JNIMacroAssemblerFwd<Riscv64Assembler, PointerSize::k64> {
 public:
  explicit Riscv64JNIMacroAssembler(ArenaAllocator* allocator)
      : JNIMacroAssemblerFwd<Riscv64Assembler, PointerSize::k64>(allocator) {}
  ~Riscv64JNIMacroAssembler();

  // Finalize the code.
  void FinalizeCode() override;

  // Emit code that will create an activation on the stack.
  void BuildFrame(size_t frame_size,
                  ManagedRegister method_reg,
                  ArrayRef<const ManagedRegister> callee_save_regs) override;

  // Emit code that will remove an activation from the stack.
  void RemoveFrame(size_t frame_size,
                   ArrayRef<const ManagedRegister> callee_save_regs,
                   bool may_suspend) override;

  void IncreaseFrameSize(size_t adjust) override;
  void DecreaseFrameSize(size_t adjust) override;

  // Store routines.
  void Store(FrameOffset offs, ManagedRegister src, size_t size) override;
  void StoreRef(FrameOffset dest, ManagedRegister src) override;
  void StoreRawPtr(FrameOffset dest, ManagedRegister src) override;
  void StoreImmediateToFrame(FrameOffset dest, uint32_t imm) override;
  void StoreStackOffsetToThread(ThreadOffset64 thr_offs, FrameOffset fr_offs) override;
  void StoreStackPointerToThread(ThreadOffset64 thr_offs) override;
  void StoreSpanning(FrameOffset dest, ManagedRegister src, FrameOffset in_off) override;

  // Load routines.
  void Load(ManagedRegister dest, FrameOffset src, size_t size) override;
  void LoadFromThread(ManagedRegister dest, ThreadOffset64 src, size_t size) override;
  void LoadRef(ManagedRegister dest, FrameOffset src) override;
  void LoadRef(ManagedRegister dest,
               ManagedRegister base,
               MemberOffset offs,
               bool unpoison_reference) override;
  void LoadRawPtr(ManagedRegister dest, ManagedRegister base, Offset offs) override;
  void LoadRawPtrFromThread(ManagedRegister dest, ThreadOffset64 offs) override;

  // Copying routines.
  void MoveArguments(ArrayRef<ArgumentLocation> dests, ArrayRef<ArgumentLocation> srcs) override;
  void Move(ManagedRegister dest, ManagedRegister src, size_t size) override;
  void CopyRawPtrFromThread(FrameOffset fr_offs, ThreadOffset64 thr_offs) override;
  void CopyRawPtrToThread(ThreadOffset64 thr_offs, FrameOffset fr_offs, ManagedRegister scratch)
      override;
  void CopyRef(FrameOffset dest, FrameOffset src) override;
  void CopyRef(FrameOffset dest,
               ManagedRegister base,
               MemberOffset offs,
               bool unpoison_reference) override;
  void Copy(FrameOffset dest, FrameOffset src, size_t size) override;
  void Copy(FrameOffset dest,
            ManagedRegister src_base,
            Offset src_offset,
            ManagedRegister scratch,
            size_t size) override;
  void Copy(ManagedRegister dest_base,
            Offset dest_offset,
            FrameOffset src,
            ManagedRegister scratch,
            size_t size) override;
  void Copy(FrameOffset dest,
            FrameOffset src_base,
            Offset src_offset,
            ManagedRegister scratch,
            size_t size) override;
  void Copy(ManagedRegister dest,
            Offset dest_offset,
            ManagedRegister src,
            Offset src_offset,
            ManagedRegister scratch,
            size_t size) override;
  void Copy(FrameOffset dest,
            Offset dest_offset,
            FrameOffset src,
            Offset src_offset,
            ManagedRegister scratch,
            size_t size) override;
  void MemoryBarrier(ManagedRegister scratch) override;

  // Sign extension.
  void SignExtend(ManagedRegister mreg, size_t size) override;

  // Zero extension.
  void ZeroExtend(ManagedRegister mreg, size_t size) override;

  // Exploit fast access in managed code to Thread::Current().
  void GetCurrentThread(ManagedRegister tr) override;
  void GetCurrentThread(FrameOffset dest_offset) override;

  // Set up out_reg to hold a Object** into the handle scope, or to be null if the
  // value is null and null_allowed. in_reg holds a possibly stale reference
  // that can be used to avoid loading the handle scope entry to see if the value is
  // null.
  void CreateHandleScopeEntry(ManagedRegister out_reg,
                              FrameOffset handlescope_offset,
                              ManagedRegister in_reg,
                              bool null_allowed);

  // Set up out_off to hold a Object** into the handle scope, or to be null if the
  // value is null and null_allowed.
  void CreateHandleScopeEntry(FrameOffset out_off,
                              FrameOffset handlescope_offset,
                              ManagedRegister scratch,
                              bool null_allowed);

  // src holds a handle scope entry (Object**) load this into dst.
  void LoadReferenceFromHandleScope(ManagedRegister dst, ManagedRegister src);

  // Set up `out_reg` to hold a `jobject` (`StackReference<Object>*` to a spilled value),
  // or to be null if the value is null and `null_allowed`. `in_reg` holds a possibly
  // stale reference that can be used to avoid loading the spilled value to
  // see if the value is null.
  void CreateJObject(ManagedRegister out_reg,
                     FrameOffset spilled_reference_offset,
                     ManagedRegister in_reg,
                     bool null_allowed) override;

  // Set up `out_off` to hold a `jobject` (`StackReference<Object>*` to a spilled value),
  // or to be null if the value is null and `null_allowed`.
  void CreateJObject(FrameOffset out_off,
                     FrameOffset spilled_reference_offset,
                     bool null_allowed) override;

  // Jump to address held at [base+offset] (used for tail calls).
  void Jump(ManagedRegister base, Offset offset) override;

  // Heap::VerifyObject on src. In some cases (such as a reference to this) we
  // know that src may not be null.
  void VerifyObject(ManagedRegister m_src, bool could_be_null) override;
  void VerifyObject(FrameOffset src, bool could_be_null) override;

  // Call to address held at [base+offset].
  void Call(ManagedRegister base, Offset offset) override;
  void Call(FrameOffset base, Offset offset) override;
  void CallFromThread(ThreadOffset64 offset) override;

  // Generate code to check if Thread::Current()->exception_ is non-null
  // and branch to a ExceptionSlowPath if it is.
  void ExceptionPoll(size_t stack_adjust) override;

  // Create a new label that can be used with Jump/Bind calls.
  std::unique_ptr<JNIMacroLabel> CreateLabel() override;
  // Emit an unconditional jump to the label.
  void Jump(JNIMacroLabel* label) override;

  // Code at this offset will serve as the target for the Jump call.
  void Bind(JNIMacroLabel* label) override;


  // Emit a conditional jump to the label by applying a unary condition test to the GC marking flag.
  void TestGcMarking(JNIMacroLabel* label, JNIMacroUnaryCondition cond) override;
};

class Riscv64JNIMacroLabel final
    : public JNIMacroLabelCommon<Riscv64JNIMacroLabel,
                                 art::Label,
                                 InstructionSet::kRiscv64> {
 public:
  art::Label* AsRiscv64() {
    return AsPlatformLabel();
  }
};

}  // namespace riscv64
}  // namespace art

#endif  // ART_COMPILER_UTILS_RISCV64_JNI_MACRO_ASSEMBLER_RISCV64_H_
