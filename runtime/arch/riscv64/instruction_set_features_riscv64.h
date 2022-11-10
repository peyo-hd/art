/*
 * Copyright (C) 2022 The Android Open Source Project
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

#ifndef ART_RUNTIME_ARCH_ARM64_INSTRUCTION_SET_FEATURES_RISCV64_H_
#define ART_RUNTIME_ARCH_ARM64_INSTRUCTION_SET_FEATURES_RISCV64_H_

#include "arch/instruction_set_features.h"

namespace art {

class Riscv64InstructionSetFeatures;
using Riscv64FeaturesUniquePtr = std::unique_ptr<const Riscv64InstructionSetFeatures>;

// Instruction set features relevant to the ARM64 architecture.
class Riscv64InstructionSetFeatures final : public InstructionSetFeatures {
 public:
  // Process a CPU variant string.
  static Riscv64FeaturesUniquePtr FromVariant(const std::string& variant, std::string* error_msg);

  // Parse a bitmap and create an InstructionSetFeatures.
  static Riscv64FeaturesUniquePtr FromBitmap(uint32_t bitmap);

  // Turn C pre-processor #defines into the equivalent instruction set features.
  static Riscv64FeaturesUniquePtr FromCppDefines();

  // Process /proc/cpuinfo and use kRuntimeISA to produce InstructionSetFeatures.
  static Riscv64FeaturesUniquePtr FromCpuInfo();

  // Process the auxiliary vector AT_HWCAP entry and use kRuntimeISA to produce
  // InstructionSetFeatures.
  static Riscv64FeaturesUniquePtr FromHwcap();

  // Use assembly tests of the current runtime (ie kRuntimeISA) to determine the
  // InstructionSetFeatures. This works around kernel bugs in AT_HWCAP and /proc/cpuinfo.
  static Riscv64FeaturesUniquePtr FromAssembly();

  // Use external cpu_features library.
  static Riscv64FeaturesUniquePtr FromCpuFeatures();

  // Return a new set of instruction set features, intersecting `this` features
  // with hardware capabilities.
  Riscv64FeaturesUniquePtr IntersectWithHwcap() const;

  bool Equals(const InstructionSetFeatures* other) const override;

  bool HasAtLeast(const InstructionSetFeatures* other) const override;

  InstructionSet GetInstructionSet() const override {
    return InstructionSet::kRiscv64;
  }

  uint32_t AsBitmap() const override;

  std::string GetFeatureString() const override;

  virtual ~Riscv64InstructionSetFeatures() {}

 protected:
  std::unique_ptr<const InstructionSetFeatures>
      AddFeaturesFromSplitString(const std::vector<std::string>& features,
                                 std::string* error_msg) const override;

  std::unique_ptr<const InstructionSetFeatures>
      AddRuntimeDetectedFeatures(const InstructionSetFeatures *features) const override;

 private:
  Riscv64InstructionSetFeatures(): InstructionSetFeatures() {}

  DISALLOW_COPY_AND_ASSIGN(Riscv64InstructionSetFeatures);
};

}  // namespace art

#endif  // ART_RUNTIME_ARCH_ARM64_INSTRUCTION_SET_FEATURES_RISCV64_H_
