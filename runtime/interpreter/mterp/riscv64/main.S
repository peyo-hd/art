%def header():
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


#define AT   t6

/*
 * It looks like the GNU assembler currently does not support the blec and bgtc
 * idioms, which should translate into bgec and bltc respectively with swapped
 * left and right register operands.
 * TODO: remove these macros when the assembler is fixed.
 */
/*.macro blec lreg, rreg, target
    bgec    \rreg, \lreg, \target
.endm
.macro bgtc lreg, rreg, target
    bltc    \rreg, \lreg, \target
.endm
*/
/*
Mterp and MIPS64 notes:

The following registers have fixed assignments:

  reg nick      purpose
  s7  rPC       interpreted program counter, used for fetching instructions
  s1  rFP       interpreted frame pointer, used for accessing locals and args
  s2  rSELF     self (Thread) pointer
  s3  rINST     first 16-bit code unit of current instruction
  s4  rIBASE    interpreted instruction base pointer, used for computed goto
  s5  rREFS     base of object references in shadow frame  (ideally, we'll get rid of this later).
  s6  rPROFILE  jit profile hotness countdown
*/

/* During bringup, we'll use the shadow frame model instead of rFP */
/* single-purpose registers, given names for clarity */
#define rPC      s7
#define CFI_DEX  23  // DWARF register number of the register holding dex-pc (s7).
#define CFI_TMP  10   // DWARF register number of the first argument register (a0).
#define rFP      s1
#define rSELF    s2
#define rINST    s3
#define rIBASE   s4
#define rREFS    s5
#define rPROFILE s6

/*
 * This is a #include, not a %include, because we want the C pre-processor
 * to expand the macros into assembler assignment statements.
 */
#include "asm_support.h"
#include "interpreter/cfi_asm_support.h"

/*
 * Instead of holding a pointer to the shadow frame, we keep rFP at the base of the vregs.  So,
 * to access other shadow frame fields, we need to use a backwards offset.  Define those here.
 */
#define OFF_FP(a) (a - SHADOWFRAME_VREGS_OFFSET)
#define OFF_FP_NUMBER_OF_VREGS OFF_FP(SHADOWFRAME_NUMBER_OF_VREGS_OFFSET)
#define OFF_FP_DEX_PC OFF_FP(SHADOWFRAME_DEX_PC_OFFSET)
#define OFF_FP_LINK OFF_FP(SHADOWFRAME_LINK_OFFSET)
#define OFF_FP_METHOD OFF_FP(SHADOWFRAME_METHOD_OFFSET)
#define OFF_FP_RESULT_REGISTER OFF_FP(SHADOWFRAME_RESULT_REGISTER_OFFSET)
#define OFF_FP_DEX_PC_PTR OFF_FP(SHADOWFRAME_DEX_PC_PTR_OFFSET)
#define OFF_FP_DEX_INSTRUCTIONS OFF_FP(SHADOWFRAME_DEX_INSTRUCTIONS_OFFSET)
#define OFF_FP_SHADOWFRAME OFF_FP(0)

#define MTERP_PROFILE_BRANCHES 1
#define MTERP_LOGGING 1

/*
 * "export" the PC to dex_pc field in the shadow frame, f/b/o future exception objects.  Must
 * be done *before* something throws.
 *
 * It's okay to do this more than once.
 *
 * NOTE: the fast interpreter keeps track of dex pc as a direct pointer to the mapped
 * dex byte codes.  However, the rest of the runtime expects dex pc to be an instruction
 * offset into the code_items_[] array.  For effiency, we will "export" the
 * current dex pc as a direct pointer using the EXPORT_PC macro, and rely on GetDexPC
 * to convert to a dex pc when needed.
 */

.macro EXPORT_PC
    sd      rPC, OFF_FP_DEX_PC_PTR(rFP)
.endm

/*
 * Refresh handler table.
 */
.macro REFRESH_IBASE
    ld      rIBASE, THREAD_CURRENT_IBASE_OFFSET(rSELF)
.endm

/*
 * Fetch the next instruction from rPC into rINST.  Does not advance rPC.
 */
.macro FETCH_INST
    lhu     rINST, 0(rPC)
.endm

/* Advance rPC by some number of code units. */
.macro ADVANCE count
    addi  rPC, rPC, (\count) * 2
.endm

/*
 * Fetch the next instruction from an offset specified by _reg and advance xPC.
 * xPC to point to the next instruction.  "_reg" must specify the distance
 * in bytes, *not* 16-bit code units, and may be a signed value.  Must not set flags.
 *
 */
.macro FETCH_ADVANCE_INST_RB reg
    add   rPC, rPC, \reg
    FETCH_INST
.endm

/*
 * Fetch the next instruction from the specified offset.  Advances rPC
 * to point to the next instruction.
 *
 * This must come AFTER anything that can throw an exception, or the
 * exception catch may miss.  (This also implies that it must come after
 * EXPORT_PC.)
 */
.macro FETCH_ADVANCE_INST count
    ADVANCE \count
    FETCH_INST
.endm

/*
 * Similar to FETCH_ADVANCE_INST, but does not update rPC.  Used to load
 * rINST ahead of possible exception point.  Be sure to manually advance rPC
 * later.
 */
.macro PREFETCH_INST count
    lhu     rINST, ((\count) * 2)(rPC)
.endm

/*
 * Put the instruction's opcode field into the specified register.
 */
.macro GET_INST_OPCODE reg
    andi     \reg, rINST, 255
.endm

/*
 * Begin executing the opcode in _reg.
 */
.macro  GOTO_OPCODE reg
    slli    AT, \reg, ${handler_size_bits}
    add     AT, rIBASE, AT
    jr      AT
    # .set at
.endm


/*
 * MIPS64 dlsa rd,rs,rt,sa
 * GPR[rd] <- (GPR[rs] << (sa+1)) + GPR[rt]
 */
 // zhengxing: For riscv, Needn't add 1 to 'sa' as it's included in input 'sa' when invoking DLSA.
.macro DLSA reg, sreg, treg, sa
    slli  AT, \sreg, \sa
    add   \reg, AT, \treg
.endm

/*
 * for ext rd,rs,pose,size
 */
.macro EXT reg, sreg, pose, size
    srli    t6, \sreg, \pose
    li      t5, -1
    slli    t5, t5, \size
    not     t5, t5
    and     t6, t6, t5
    addi    \reg, t6, 0
    # addiw   reg, t6, 0
.endm

/*
 * for ins rd,rs,pose,size
 */
.macro INS reg, sreg, pose, size
    li      t5, -1
    slli    t5, t5, \size
    not     t5, t5
    and     t0, \sreg, t5
    slli    t0, t0, \pose

    slli    t5, t5,  \pose
    not     t5, t5
    and     \reg, \reg, t5

    or      \reg, \reg, t0
    sext.w  \reg, \reg
.endm

/*
 * for dins rd,rs,pose,size
 */
.macro DINS reg, sreg, pose, size
    li      t5, -1
    slli    t5, t5, \size
    not     t5, t5
    and     \sreg, \sreg, t5
    slli    \sreg, \sreg, \pose

    slli    t5, t5,  \pose
    not     t5, t5
    and     \reg, \reg, t5

    or      \reg, \reg, \sreg
    # sext.w  \reg, \reg
.endm

/*
 * for dinsu rd,rs,pose,size
 */
.macro DINSU reg, sreg, pose, size
    li      t5, -1
    slli    t5, t5, \size
    not     t5, t5
    and     t0, \sreg, t5
    slli    t0, t0, \pose

    slli    t5, t5,  \pose
    not     t5, t5
    and     \reg, \reg, t5

    or      \reg, \reg, t0
    # sext.w  \reg, \reg
.endm

/*
 * Get/set the 32-bit value from a Dalvik register.
 * Note, GET_VREG does sign extension to 64 bits while
 * GET_VREG_U does zero extension to 64 bits.
 * One is useful for arithmetic while the other is
 * useful for storing the result value as 64-bit.
 */
.macro GET_VREG reg, vreg
    DLSA    AT, \vreg, rFP, 2
    lw      \reg, 0(AT)
.endm
.macro GET_VREG_U reg, vreg
    DLSA    AT, \vreg, rFP, 2
    lwu     \reg, 0(AT)
.endm
.macro GET_VREG_FLOAT reg, vreg
    DLSA    AT, \vreg, rFP, 2
    flw     \reg, 0(AT)
.endm
.macro SET_VREG reg, vreg
    DLSA    AT, \vreg, rFP, 2
    sw      \reg, 0(AT)
    DLSA    AT, \vreg, rREFS, 2
    sw      zero, 0(AT)
.endm
.macro SET_VREG_OBJECT reg, vreg
    DLSA    AT, \vreg, rFP, 2
    sw      \reg, 0(AT)
    DLSA    AT, \vreg, rREFS, 2
    sw      \reg, 0(AT)
.endm
.macro SET_VREG_FLOAT reg, vreg
    DLSA    AT, \vreg, rFP, 2
    fsw    \reg, 0(AT)
    DLSA    AT, \vreg, rREFS, 2
    sw      zero, 0(AT)
.endm

/*
 * Get/set the 64-bit value from a Dalvik register.
 * Avoid unaligned memory accesses.
 * Note, SET_VREG_WIDE clobbers the register containing the value being stored.
 * Note, SET_VREG_DOUBLE clobbers the register containing the Dalvik register number.
 */
.macro GET_VREG_WIDE reg, vreg
    DLSA    AT, \vreg, rFP, 2
    ld      \reg, 0(AT)
.endm
.macro GET_VREG_DOUBLE reg, vreg
    DLSA    AT, \vreg, rFP, 2
    fld    \reg, 0(AT)
.endm
.macro SET_VREG_WIDE reg, vreg
    DLSA    AT, \vreg, rFP, 2
    sd      \reg, 0(AT)

    DLSA    AT, \vreg, rREFS, 2
    sd      zero, 0(AT)
.endm
.macro SET_VREG_DOUBLE reg, vreg
    DLSA    AT, \vreg, rFP, 2
    fsd    \reg, 0(AT)
    
    DLSA    AT, \vreg, rREFS, 2
    sd      zero, 0(AT)
.endm

/*
 * On-stack offsets for spilling/unspilling callee-saved registers
 * and the frame size.
 */
#define STACK_OFFSET_RA 0
// #define STACK_OFFSET_GP 8
#define STACK_OFFSET_S0 16
#define STACK_OFFSET_S1 24
#define STACK_OFFSET_S2 32
#define STACK_OFFSET_S3 40
#define STACK_OFFSET_S4 48
#define STACK_OFFSET_S5 56
#define STACK_OFFSET_S6 64
#define STACK_OFFSET_S7 72
#define STACK_OFFSET_S8 80
#define STACK_OFFSET_S9 88
#define STACK_OFFSET_S10 96
#define STACK_OFFSET_S11 104
#define STACK_SIZE       112    /* needs 16 byte alignment */

/* Constants for float/double_to_int/long conversions */
#define INT_MIN             0x80000000
#define INT_MIN_AS_FLOAT    0xCF000000
#define INT_MIN_AS_DOUBLE   0xC1E0000000000000
#define LONG_MIN            0x8000000000000000
#define LONG_MIN_AS_FLOAT   0xDF000000
#define LONG_MIN_AS_DOUBLE  0xC3E0000000000000


/*
 * function support macros.
 */
.macro ENTRY name
    .type \name, %function
    .hidden \name  // Hide this as a global symbol, so we do not incur plt calls.
    .global \name
    /* Cache alignment for function entry */
    .balign 16
\name:
.endm

.macro END name
    .size \name, .-\name
.endm


%def entry():
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

/*
 * Interpreter entry point.
 */

     # .set    reorder

    .text
    .global ExecuteMterpImpl
    .type   ExecuteMterpImpl, %function
    .balign 16
/*
 * On entry:
 *  a0  Thread* self
 *  a1  dex_instructions
 *  a2  ShadowFrame
 *  a3  JValue* result_register
 *
 */

ENTRY ExecuteMterpImpl
    .cfi_startproc

    .cfi_def_cfa sp, 0
    addi  sp, sp, -STACK_SIZE
    .cfi_adjust_cfa_offset STACK_SIZE

    sd      ra, STACK_OFFSET_RA(sp)
    .cfi_rel_offset ra, STACK_OFFSET_RA

    sd      s0, STACK_OFFSET_S0(sp)
    .cfi_rel_offset s9, STACK_OFFSET_S0
    sd      s1, STACK_OFFSET_S1(sp)
    .cfi_rel_offset s1, STACK_OFFSET_S1
    sd      s2, STACK_OFFSET_S2(sp)
    .cfi_rel_offset s2, STACK_OFFSET_S2
    sd      s3, STACK_OFFSET_S3(sp)
    .cfi_rel_offset s3, STACK_OFFSET_S3
    sd      s4, STACK_OFFSET_S4(sp)
    .cfi_rel_offset s4, STACK_OFFSET_S4
    sd      s5, STACK_OFFSET_S5(sp)
    .cfi_rel_offset s5, STACK_OFFSET_S5
    sd      s6, STACK_OFFSET_S6(sp)
    .cfi_rel_offset s6, STACK_OFFSET_S6
    sd      s7, STACK_OFFSET_S7(sp)
    .cfi_rel_offset s7, STACK_OFFSET_S7
    sd      s8, STACK_OFFSET_S8(sp)
    .cfi_rel_offset s8, STACK_OFFSET_S8
    sd      s9, STACK_OFFSET_S9(sp)
    .cfi_rel_offset s9, STACK_OFFSET_S9
    sd      s10, STACK_OFFSET_S10(sp)
    .cfi_rel_offset s10, STACK_OFFSET_S10
    sd      s11, STACK_OFFSET_S11(sp)
    .cfi_rel_offset s11, STACK_OFFSET_S11

    /* Remember the return register */
    sd      a3, SHADOWFRAME_RESULT_REGISTER_OFFSET(a2)

    /* Remember the dex instruction pointer */
    sd      a1, SHADOWFRAME_DEX_INSTRUCTIONS_OFFSET(a2)

    /* set up "named" registers */
    move    rSELF, a0
    addi    rFP, a2, SHADOWFRAME_VREGS_OFFSET
    lw      t4, SHADOWFRAME_NUMBER_OF_VREGS_OFFSET(a2)
    DLSA    rREFS, t4, rFP, 2
    lw      t4, SHADOWFRAME_DEX_PC_OFFSET(a2)
    DLSA    rPC, t4, a1, 1
    CFI_DEFINE_DEX_PC_WITH_OFFSET(CFI_TMP, CFI_DEX, 0)
    EXPORT_PC

    /* Starting ibase */
    REFRESH_IBASE

    /* Set up for backwards branches & osr profiling */
    ld      a0, OFF_FP_METHOD(rFP)
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rSELF 
    jal     MterpSetUpHotnessCountdown
    move    rPROFILE, a0                # Starting hotness countdown to rPROFILE

    /* start executing the instruction at rPC */
    FETCH_INST
    GET_INST_OPCODE t4
    GOTO_OPCODE t4

    /* NOTE: no fallthrough */
    END ExecuteMterpImpl

%def dchecks_before_helper():
    // Call C++ to do debug checks and return to the handler using tail call.
    .extern MterpCheckBefore
    la      t6, MterpCheckBefore
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rPC
    jalr    zero, t6                            # (self, shadow_frame, dex_pc_ptr) Note: tail call.

%def opcode_pre():
%  add_helper(dchecks_before_helper, "mterp_dchecks_before_helper")
#if 0
    move    rPROFILE, zero
    lw      a0, 0(rPC)
    andi    a0, a0, 0xFF
    slli    a0, a0, 2
    .extern instruction_configs
    la      t4, instruction_configs
    add     t4, t4, a0
    lw      t4, 0(t4)
    EXPORT_PC
    beqz    t4, MterpCommonFallback
#endif
    #if !defined(NDEBUG)
    jal    mterp_dchecks_before_helper
    #endif

%def footer():
    # .cfi_endproc
    END MterpHelpers

%def fallback():
/* Transfer stub to alternate interpreter */
    j       MterpFallback

%def helpers():
    ENTRY MterpHelpers

/*
 * We've detected a condition that will result in an exception, but the exception
 * has not yet been thrown.  Just bail out to the reference interpreter to deal with it.
 * TUNING: for consistency, we may want to just go ahead and handle these here.
 */

    .extern MterpLogDivideByZeroException
common_errDivideByZero:
    EXPORT_PC
#if MTERP_LOGGING
    move    a0, rSELF
    addi   a1, rFP, OFF_FP_SHADOWFRAME
    jal     MterpLogDivideByZeroException
#endif
    j       MterpCommonFallback

    .extern MterpLogArrayIndexException
common_errArrayIndex:
    EXPORT_PC
#if MTERP_LOGGING
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    jal     MterpLogArrayIndexException
#endif
    j       MterpCommonFallback

    .extern MterpLogNullObjectException
common_errNullObject:
    EXPORT_PC
#if MTERP_LOGGING
    move    a0, rSELF
    addi     a1, rFP, OFF_FP_SHADOWFRAME
    jal     MterpLogNullObjectException
#endif
    j       MterpCommonFallback

/*
 * If we're here, something is out of the ordinary.  If there is a pending
 * exception, handle it.  Otherwise, roll back and retry with the reference
 * interpreter.
 */
MterpPossibleException:
    ld      a0, THREAD_EXCEPTION_OFFSET(rSELF)
    beqz    a0, MterpFallback                       # If not, fall back to reference interpreter.
    /* intentional fallthrough - handle pending exception. */
/*
 * On return from a runtime helper routine, we've found a pending exception.
 * Can we handle it here - or need to bail out to caller?
 *
 */
    .extern MterpHandleException
MterpException:
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    jal     MterpHandleException                    # (self, shadow_frame)
    beqz    a0, MterpExceptionReturn                # no local catch, back to caller.
    ld      a0, OFF_FP_DEX_INSTRUCTIONS(rFP)
    lwu     a1, OFF_FP_DEX_PC(rFP)
    REFRESH_IBASE
    DLSA    rPC, a1, a0, 1                          # generate new dex_pc_ptr
    /* Do we need to switch interpreters? */
    lw      a0, THREAD_USE_MTERP_OFFSET(rSELF)
    beqz    a0, MterpFallback
    /* resume execution at catch block */
    EXPORT_PC
    FETCH_INST
    GET_INST_OPCODE a0
    GOTO_OPCODE a0
    /* NOTE: no fallthrough */

/*
 * Common handling for branches with support for Jit profiling.
 * On entry:
 *    rINST          <= signed offset
 *    rPROFILE       <= signed hotness countdown (expanded to 64 bits)
 *
 * We have quite a few different cases for branch profiling, OSR detection and
 * suspend check support here.
 *
 * Taken backward branches:
 *    If profiling active, do hotness countdown and report if we hit zero.
 *    If in osr check mode, see if our target is a compiled loop header entry and do OSR if so.
 *    Is there a pending suspend request?  If so, suspend.
 *
 * Taken forward branches and not-taken backward branches:
 *    If in osr check mode, see if our target is a compiled loop header entry and do OSR if so.
 *
 * Our most common case is expected to be a taken backward branch with active jit profiling,
 * but no full OSR check and no pending suspend request.
 * Next most common case is not-taken branch with no full OSR check.
 *
 */
MterpCommonTakenBranchNoFlags:
    bgtz    rINST, .L_forward_branch    # don't add forward branches to hotness
/*
 * We need to subtract 1 from positive values and we should not see 0 here,
 * so we may use the result of the comparison with -1.
 */
    li      t4, JIT_CHECK_OSR
    beq     rPROFILE, t4, .L_osr_check
    blt     rPROFILE, t4, .L_resume_backward_branch
    addi    rPROFILE, rPROFILE, -1
    beqz    rPROFILE, .L_add_batch      # counted down to zero - report
.L_resume_backward_branch:
    lw      ra, THREAD_FLAGS_OFFSET(rSELF)
    REFRESH_IBASE
    add     a2, rINST, rINST            # a2<- byte offset
    FETCH_ADVANCE_INST_RB a2            # update rPC, load rINST
    andi    ra, ra, THREAD_SUSPEND_OR_CHECKPOINT_REQUEST
    bnez    ra, .L_suspend_request_pending
    GET_INST_OPCODE a0                  # extract opcode from rINST
    GOTO_OPCODE a0                      # jump to next instruction

.L_suspend_request_pending:
    EXPORT_PC
    move    a0, rSELF
    jal     MterpSuspendCheck           # (self)
    bnez    a0, MterpFallback
    REFRESH_IBASE                       # might have changed during suspend
    GET_INST_OPCODE a0                  # extract opcode from rINST
    GOTO_OPCODE a0                      # jump to next instruction

.L_no_count_backwards:
    li      t4, JIT_CHECK_OSR           # check for possible OSR re-entry
    bne     rPROFILE, t4, .L_resume_backward_branch
.L_osr_check:
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rINST
    EXPORT_PC
    jal MterpMaybeDoOnStackReplacement  # (self, shadow_frame, offset)
    bnez    a0, MterpOnStackReplacement
    j       .L_resume_backward_branch

.L_forward_branch:
    li      t4, JIT_CHECK_OSR           # check for possible OSR re-entry
    beq     rPROFILE, t4, .L_check_osr_forward
.L_resume_forward_branch:
    add     a2, rINST, rINST            # a2<- byte offset
    FETCH_ADVANCE_INST_RB a2            # update rPC, load rINST
    GET_INST_OPCODE a0                # extract opcode from rINST
    GOTO_OPCODE a0                      # jump to next instruction

.L_check_osr_forward:
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rINST
    EXPORT_PC
    jal     MterpMaybeDoOnStackReplacement # (self, shadow_frame, offset)
    bnez    a0, MterpOnStackReplacement
    j       .L_resume_forward_branch

.L_add_batch:
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    sh      rPROFILE, SHADOWFRAME_HOTNESS_COUNTDOWN_OFFSET(a1)
    ld      a0, OFF_FP_METHOD(rFP)
    move    a2, rSELF   
    jal     MterpAddHotnessBatch        # (method, shadow_frame, self)
    move    rPROFILE, a0                # restore new hotness countdown to rPROFILE
    j       .L_no_count_backwards

/*
 * Entered from the conditional branch handlers when OSR check request active on
 * not-taken path.  All Dalvik not-taken conditional branch offsets are 2.
 */
.L_check_not_taken_osr:
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    li      a2, 2
    EXPORT_PC
    jal     MterpMaybeDoOnStackReplacement # (self, shadow_frame, offset)
    bnez    a0, MterpOnStackReplacement
    FETCH_ADVANCE_INST 2
    GET_INST_OPCODE a0                  # extract opcode from rINST
    GOTO_OPCODE a0                      # jump to next instruction

/*
 * On-stack replacement has happened, and now we've returned from the compiled method.
 */
MterpOnStackReplacement:
#if MTERP_LOGGING
    move    a0, rSELF
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rINST                               # rINST contains offset
    jal     MterpLogOSR
#endif
    li      a0, 1                                   # Signal normal return
    j       MterpDone

/*
 * Bail out to reference interpreter.
 */
    .extern MterpLogFallback
MterpFallback:
    EXPORT_PC
#if MTERP_LOGGING
    move    a0, rSELF
    addi a1, rFP, OFF_FP_SHADOWFRAME
    jal     MterpLogFallback
#endif
MterpCommonFallback:
    li      a0, 0                                   # signal retry with reference interpreter.
    j       MterpDone

/*
 * We pushed some registers on the stack in ExecuteMterpImpl, then saved
 * SP and RA.  Here we restore SP, restore the registers, and then restore
 * RA to PC.
 *
 * On entry:
 *  uint32_t* rFP  (should still be live, pointer to base of vregs)
 */
MterpExceptionReturn:
    li      a0, 1                                   # signal return to caller.
    j       MterpDone
/*
 * Returned value is expected in a0 and if it's not 64-bit, the 32 most
 * significant bits of a0 must be zero-extended or sign-extended
 * depending on the return type.
 */
MterpReturn:
    ld      a2, OFF_FP_RESULT_REGISTER(rFP)
    sd      a0, 0(a2)
    li      a0, 1                                   # signal return to caller.
MterpDone:
/*
 * At this point, we expect rPROFILE to be non-zero.  If negative, hotness is disabled or we're
 * checking for OSR.  If greater than zero, we might have unreported hotness to register
 * (the difference between the ending rPROFILE and the cached hotness counter).  rPROFILE
 * should only reach zero immediately after a hotness decrement, and is then reset to either
 * a negative special state or the new non-zero countdown value.
 */
    blez    rPROFILE, .L_pop_and_return # if > 0, we may have some counts to report.

MterpProfileActive:
    move    rINST, a0                   # stash return value
    /* Report cached hotness counts */
    ld      a0, OFF_FP_METHOD(rFP)
    addi    a1, rFP, OFF_FP_SHADOWFRAME
    move    a2, rSELF
    sh      rPROFILE, SHADOWFRAME_HOTNESS_COUNTDOWN_OFFSET(a1)
    jal     MterpAddHotnessBatch        # (method, shadow_frame, self)
    move    a0, rINST                   # restore return value

.L_pop_and_return:
    .cfi_remember_state
    ld      s11, STACK_OFFSET_S11(sp)
    .cfi_restore s11
    ld      s10, STACK_OFFSET_S10(sp)
    .cfi_restore s10
    ld      s9, STACK_OFFSET_S9(sp)
    .cfi_restore s9
    ld      s8, STACK_OFFSET_S8(sp)
    .cfi_restore s8
    ld      s7, STACK_OFFSET_S7(sp)
    .cfi_restore s7
    ld      s6, STACK_OFFSET_S6(sp)
    .cfi_restore s6
    ld      s5, STACK_OFFSET_S5(sp)
    .cfi_restore s5
    ld      s4, STACK_OFFSET_S4(sp)
    .cfi_restore s4
    ld      s3, STACK_OFFSET_S3(sp)
    .cfi_restore s3
    ld      s2, STACK_OFFSET_S2(sp)
    .cfi_restore s2
    ld      s1, STACK_OFFSET_S1(sp)
    .cfi_restore s1
    ld      s0, STACK_OFFSET_S0(sp)
    .cfi_restore s0

    ld      ra, STACK_OFFSET_RA(sp)
    .cfi_restore ra

    # ld      t8, STACK_OFFSET_GP(sp)
    # .cpreturn
    # .cfi_restore 28

    # .set    noreorder
    addi  sp, sp, STACK_SIZE
    .cfi_adjust_cfa_offset -STACK_SIZE
    jr      ra

    .cfi_restore_state                              // Reset unwind info so following code unwinds.
    .cfi_def_cfa_offset STACK_SIZE                  // workaround for clang bug: 31975598

    .cfi_endproc
    # .set    reorder
    # .size ExecuteMterpImpl, .-ExecuteMterpImpl

%def instruction_end():

    .hidden artMterpAsmInstructionEnd
    .global artMterpAsmInstructionEnd
artMterpAsmInstructionEnd:

%def instruction_start():

    .hidden artMterpAsmInstructionStart
    .global artMterpAsmInstructionStart
artMterpAsmInstructionStart = .L_op_nop
    .text

%def opcode_start():
    ENTRY mterp_${opcode}
%def opcode_end():
    END mterp_${opcode}
%def helper_start(name):
    ENTRY ${name}
%def helper_end(name):
    END ${name}
