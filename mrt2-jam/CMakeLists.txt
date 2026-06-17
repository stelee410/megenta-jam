# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Jam standalone macOS app.
# Resources (musiccoca, spectrostream) are loaded from ~/Documents/Magenta/magenta-rt-v2/resources/
# at runtime — see common/cpp/magenta_paths.h.

set(APP_ICON "${CMAKE_CURRENT_SOURCE_DIR}/common/assets/AppIcon.icns")
set_source_files_properties(${APP_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")

# Vendored demucs.cpp (https://github.com/sevagh/demucs.cpp, MIT) — neural
# 4-stem separation (htdemucs) used by the PGM studio.
add_library(demucscpp STATIC
    vendor/demucscpp/crosstransformer.cpp
    vendor/demucscpp/dsp.cpp
    vendor/demucscpp/encdec.cpp
    vendor/demucscpp/layers.cpp
    vendor/demucscpp/lstm.cpp
    vendor/demucscpp/model_apply.cpp
    vendor/demucscpp/model_inference.cpp
    vendor/demucscpp/model_load.cpp
)
target_include_directories(demucscpp PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/demucscpp
    ${eigen_SOURCE_DIR}
)
target_compile_options(demucscpp PRIVATE -O3 -ffast-math)
# Route Eigen's GEMM through Apple Accelerate (AMX) — big transformer speedup.
target_compile_definitions(demucscpp PUBLIC EIGEN_USE_BLAS)
target_link_libraries(demucscpp PUBLIC "-framework Accelerate")
set_target_properties(demucscpp PROPERTIES CXX_STANDARD 17)

add_executable(mrt2_jam MACOSX_BUNDLE
    JamApp.mm
    JamAppController.mm
    JamSeparate.mm
    JamTranscribe.mm
    JamTranscribePiano.mm
    JamRoformer.mm
    LyriaClient.mm
    LyriaConductor.mm
    ${CMAKE_CURRENT_SOURCE_DIR}/common/cpp/magenta_paths.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/common/objc/MagentaModelManager.mm
    ${CMAKE_CURRENT_SOURCE_DIR}/common/objc/MagentaModelDownloader.mm
    ${CMAKE_CURRENT_SOURCE_DIR}/common/objc/MagentaSettings.mm
    ${APP_ICON}
)

target_include_directories(mrt2_jam PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/common/cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/common/objc
    ${ONNXRUNTIME_DIR}/include
)
target_compile_options(mrt2_jam PRIVATE -fobjc-arc)
# The separation wrapper instantiates Eigen kernels — keep it optimized.
set_source_files_properties(JamSeparate.mm PROPERTIES COMPILE_OPTIONS "-O3")

target_link_libraries(mrt2_jam PRIVATE
    magentart::core
    demucscpp
    "${ONNXRUNTIME_DIR}/lib/libonnxruntime.1.20.1.dylib"
    "-framework Accelerate"
    "-framework AppKit"
    "-framework AudioToolbox"
    "-framework AVFoundation"
    "-framework CoreAudio"
    "-framework CoreMIDI"
    "-framework WebKit"
    "-framework UniformTypeIdentifiers"
    "-framework IOKit"
)

set_target_properties(mrt2_jam PROPERTIES
    BUILD_RPATH "@executable_path/../Frameworks"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/JamInfo.plist.in"
    MACOSX_BUNDLE_EXECUTABLE_NAME MRT2_Jam
    MACOSX_BUNDLE_BUNDLE_NAME "VerveFlow"
    MACOSX_BUNDLE_ICON_FILE "AppIcon.icns"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "co.linkyun.vervflow"
)

# ─── Jam React UI Build Target ─────────────────────────────────────────
# Self-contained npm workspace (common/react_ui + ui live under this product).
add_custom_target(npm_install_jam
    COMMAND npm install
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Installing MRT2-Jam UI workspace..."
)
add_custom_target(build_jam_ui ALL
    COMMAND npm run build
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/ui
    COMMENT "Building Jam UI..."
)
add_dependencies(build_jam_ui npm_install_jam)
add_dependencies(mrt2_jam build_jam_ui)

# ─── Deploy standalone app ───────────────────────────────────────────────────
add_custom_target(deploy_mrt2_jam
    DEPENDS mrt2_jam
    # Copy Jam UI dist into app Resources
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/Resources/jam_ui"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${CMAKE_CURRENT_SOURCE_DIR}/ui/dist"
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/Resources/jam_ui"
    # Copy mlx.metallib next to the binary
    COMMAND ${CMAKE_COMMAND} -E copy
        "${mlx_BINARY_DIR}/mlx/backend/metal/kernels/mlx.metallib"
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/MacOS/mlx.metallib"
    # Bundle onnxruntime into Frameworks
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${ONNXRUNTIME_DIR}/lib/libonnxruntime.1.20.1.dylib"
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/Frameworks/libonnxruntime.1.20.1.dylib"
    # Sign inside-out: nested binaries first, then the outer bundle.
    COMMAND codesign ${CODESIGN_FLAGS}
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/Frameworks/libonnxruntime.1.20.1.dylib"
    COMMAND codesign ${CODESIGN_FLAGS}
        "$<TARGET_BUNDLE_DIR:mrt2_jam>/Contents/MacOS/mlx.metallib"
    COMMAND codesign ${CODESIGN_FLAGS}
        --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/JamEntitlements.plist"
        --generate-entitlement-der
        "$<TARGET_BUNDLE_DIR:mrt2_jam>"
    # Deploy to ~/Applications
    COMMAND ${CMAKE_COMMAND} -E remove_directory
        "$ENV{HOME}/Applications/VerveFlow.app"
    COMMAND ditto
        "$<TARGET_BUNDLE_DIR:mrt2_jam>"
        "$ENV{HOME}/Applications/VerveFlow.app"
    COMMENT "Building and deploying VerveFlow standalone app"
    VERBATIM
)

# Notarize the deployed VerveFlow.app (requires Developer ID).
magentart_add_notarize_target(notarize_mrt2_jam
    APP "$ENV{HOME}/Applications/VerveFlow.app"
    DEPENDS deploy_mrt2_jam
    ZIP_NAME "VerveFlow.zip"
)
