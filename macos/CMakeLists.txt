# Swift is optional so the existing CMake/Qt build remains a rollback path on every platform.
if (NOT CMAKE_GENERATOR MATCHES "Ninja|Xcode")
    message(FATAL_ERROR "ENABLE_MACOS_NATIVE_UI requires the Ninja or Xcode CMake generator; use a fresh build directory. The Qt UI can still use the existing generator.")
endif ()
enable_language(Swift)
set(CMAKE_Swift_LANGUAGE_VERSION 5)
set(NATIVE_ARCH "${CMAKE_OSX_ARCHITECTURES}")
if (NOT NATIVE_ARCH)
    set(NATIVE_ARCH "${CMAKE_HOST_SYSTEM_PROCESSOR}")
endif ()
list(LENGTH NATIVE_ARCH NATIVE_ARCH_COUNT)
if (NOT NATIVE_ARCH_COUNT EQUAL 1)
    message(FATAL_ERROR "Build the native UI for one architecture at a time; a universal native bundle is not validated.")
endif ()

add_library(caesium_native_bridge STATIC
    Bridge/NativeSession.mm
    ../src/utils/LanguageManager.cpp
    ../src/utils/PostCompressionActions.cpp)
target_include_directories(caesium_native_bridge PUBLIC Bridge)
target_link_libraries(caesium_native_bridge PUBLIC caesium_core "-framework AppKit" "-framework Foundation")
foreach(PLATFORM_SOURCE IN LISTS OSX_SOURCES)
    target_sources(caesium_native_bridge PRIVATE "${PROJECT_SOURCE_DIR}/${PLATFORM_SOURCE}")
endforeach()
target_link_libraries(caesium_native_bridge PUBLIC ${OSX_FRAMEWORKS})
# The retained Sparkle 1 wrapper uses manual retain/release; ARC is scoped to the new adapter.
set_source_files_properties(Bridge/NativeSession.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

set(NATIVE_SWIFT_SOURCES
    UI/BatchStore.swift UI/BatchView.swift UI/AuxiliaryViews.swift
    UI/LinkedImageView.swift UI/NativeWindow.swift UI/MockBatch.swift)
add_library(caesium_native_ui STATIC ${NATIVE_SWIFT_SOURCES})
set_target_properties(caesium_native_ui PROPERTIES
    Swift_MODULE_NAME CaesiumNativeUI
    Swift_LANGUAGE_VERSION 5
    AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
target_compile_options(caesium_native_ui PRIVATE
    -target "${NATIVE_ARCH}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}"
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Bridge/NativeSession.h")
target_link_libraries(caesium_native_ui PUBLIC caesium_native_bridge "-framework SwiftUI" "-framework Combine" "-framework UserNotifications")
target_sources(${TARGET} PRIVATE Bridge/NativeBootstrap.mm)
set_source_files_properties(Bridge/NativeBootstrap.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_compile_definitions(${TARGET} PRIVATE CAESIUM_NATIVE_UI)
target_link_libraries(${TARGET} PRIVATE caesium_native_ui)

# C++ remains the executable's entry point. Swift objects carry their autolink directives;
# expose the selected toolchain's compatibility libraries to the Apple linker.
execute_process(COMMAND "${CMAKE_Swift_COMPILER}" -print-target-info
    OUTPUT_VARIABLE SWIFT_TARGET_INFO COMMAND_ERROR_IS_FATAL ANY)
string(JSON SWIFT_RUNTIME_PATH GET "${SWIFT_TARGET_INFO}" paths runtimeLibraryPaths 0)
target_link_directories(${TARGET} PRIVATE "${SWIFT_RUNTIME_PATH}")
target_link_libraries(${TARGET} PRIVATE "-framework SwiftUI" "-framework Combine")

if (BUILD_TESTING)
    find_package(Qt6 COMPONENTS Test REQUIRED)
    add_executable(NativeBridgeTests ../tests/NativeBridgeTests.mm
        "${CMAKE_BINARY_DIR}/languages.qrc" "${PROJECT_SOURCE_DIR}/resources/resources.qrc")
    target_compile_options(NativeBridgeTests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
    target_link_libraries(NativeBridgeTests PRIVATE caesium_native_bridge Qt6::Test ${OSX_FRAMEWORKS})
    add_dependencies(NativeBridgeTests ${TARGET})
    add_test(NAME NativeBridgeTests COMMAND NativeBridgeTests)
    set_tests_properties(NativeBridgeTests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen" TIMEOUT 90)

    # A WindowServer is required. Build the runner, but opt into registering it with CTest.
    add_library(caesium_native_ui_smoke STATIC ${NATIVE_SWIFT_SOURCES} ../tests/NativeUISmoke.swift)
    set_target_properties(caesium_native_ui_smoke PROPERTIES Swift_MODULE_NAME CaesiumNativeUISmoke
        Swift_LANGUAGE_VERSION 5 AUTOMOC OFF AUTOUIC OFF AUTORCC OFF)
    target_compile_options(caesium_native_ui_smoke PRIVATE
        -target "${NATIVE_ARCH}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}"
        -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Bridge/NativeSession.h")
    target_link_libraries(caesium_native_ui_smoke PUBLIC caesium_native_bridge "-framework SwiftUI" "-framework Combine" "-framework UserNotifications")
    add_executable(NativeUiTests ../tests/NativeUITests.mm
        "${CMAKE_BINARY_DIR}/languages.qrc" "${PROJECT_SOURCE_DIR}/resources/resources.qrc")
    target_link_libraries(NativeUiTests PRIVATE caesium_native_ui_smoke ${OSX_FRAMEWORKS})
    target_link_directories(NativeUiTests PRIVATE "${SWIFT_RUNTIME_PATH}")
    target_compile_definitions(NativeUiTests PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:CAESIUM_NATIVE_ARTIFACT_DIR=\"${CMAKE_BINARY_DIR}/test-artifacts\">")
    add_dependencies(NativeUiTests ${TARGET})
    option(ENABLE_MACOS_NATIVE_GUI_TESTS "Register native GUI tests (requires WindowServer)" OFF)
    if (ENABLE_MACOS_NATIVE_GUI_TESTS)
        add_test(NAME NativeUiTests COMMAND NativeUiTests)
        set_tests_properties(NativeUiTests PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=cocoa" TIMEOUT 100)
    endif ()
endif ()
