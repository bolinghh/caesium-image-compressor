cmake_minimum_required(VERSION 3.19)
include(ExternalProject)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_INCLUDE_CURRENT_DIR ON)
set(TARGET caesium_image_compressor)
file(STRINGS "libcaesium.conf" LIBCAESIUM_VERSION)
if (WIN32)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
    if (DEFINED PORTABLE AND PORTABLE)
        message("-- Configuring for portable")
        add_compile_definitions(IS_PORTABLE)
    endif ()
elseif (APPLE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-deprecated-declarations -Wno-deprecated-register -Wno-deprecated")
else ()
    include(GNUInstallDirs)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-deprecated-declarations -Wno-deprecated-register -Wno-deprecated")
endif ()
set_directory_properties(PROPERTIES CLEAN_NO_CUSTOM 1)

if (APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12")
    project(${TARGET} LANGUAGES CXX OBJCXX)
else ()
    project(${TARGET} LANGUAGES CXX)
endif ()

find_library(LIBCAESIUM caesium)
if (NOT LIBCAESIUM)
    find_program(CARGO "cargo" REQUIRED)
endif ()

add_compile_definitions("$<$<COMPILE_LANGUAGE:CXX,OBJCXX>:QT_DISABLE_DEPRECATED_BEFORE=0x050F00>")

set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

set(CMAKE_AUTOUIC_SEARCH_PATHS "${CMAKE_SOURCE_DIR}/views")

if (APPLE)
    set(MACOSX_BUNDLE_ICON_FILE icon.icns)
    set(CAESIUM_ICON ${CMAKE_CURRENT_SOURCE_DIR}/resources/icons/icon.icns)
    set_source_files_properties(${CAESIUM_ICON} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
elseif (WIN32)
    set(CAESIUM_ICON ${CMAKE_CURRENT_SOURCE_DIR}/resources/icons.rc)
endif ()

if (WIN32)
    set(WINSPARKLE_LIB_DIR ${CMAKE_BINARY_DIR}/libwinsparkle-prefix/src/libwinsparkle/x64/Release)
    link_directories(${WINSPARKLE_LIB_DIR})
endif ()

if (APPLE)
    option(ENABLE_MACOS_UPDATER "Build Sparkle integration" ON)
    if (ENABLE_MACOS_UPDATER)
        find_library(SPARKLE_FRAMEWORK Sparkle PATHS /Library/Frameworks REQUIRED)
        if (SPARKLE_INCLUDE_DIR)
            include_directories(${SPARKLE_INCLUDE_DIR})
        endif ()
        add_compile_definitions(HAVE_SPARKLE)
    endif ()
endif ()

set(LIBCAESIUM_SOURCE_DIR ${CMAKE_BINARY_DIR}/libcaesium-prefix/src/libcaesium)

if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release")
endif ()

string(TOLOWER ${CMAKE_BUILD_TYPE} LIBCAESIUM_BUILD_TYPE)

if (NOT WIN32 AND NOT LIBCAESIUM)
    link_directories(${LIBCAESIUM_SOURCE_DIR}/target/${LIBCAESIUM_BUILD_TYPE})
endif ()
find_package(Qt6 6.8 COMPONENTS Widgets Core Gui Concurrent Svg Network LinguistTools REQUIRED)
set(QT_VERSION_MAJOR 6)
# Qt 6.8 references AGL even on SDKs which no longer ship it.
if (APPLE AND TARGET WrapOpenGL::WrapOpenGL)
    get_target_property(OPENGL_LINKS WrapOpenGL::WrapOpenGL INTERFACE_LINK_LIBRARIES)
    list(FILTER OPENGL_LINKS EXCLUDE REGEX "AGL")
    set_property(TARGET WrapOpenGL::WrapOpenGL PROPERTY INTERFACE_LINK_LIBRARIES "${OPENGL_LINKS}")
endif ()
include(CTest)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/src/include)

set(SOURCES
        src/main.cpp
        src/utils/Theme.cpp
        src/MainWindow.cpp
        src/models/CImage.cpp
        src/models/CImageTreeItem.cpp
        src/models/CImageTreeModel.cpp
        src/models/CImageSortFilterProxyModel.cpp
        src/utils/Utils.cpp
        src/utils/LanguageManager.cpp
        src/utils/Logger.cpp
        src/utils/PostCompressionActions.cpp
        src/dialogs/AboutDialog.cpp
        src/widgets/QDropTreeView.cpp
        src/widgets/QDropListWidget.cpp
        src/widgets/QZoomGraphicsView.cpp
        src/widgets/QCaesiumMessageBox.cpp
        src/widgets/QMainCheckBox.cpp
        src/widgets/QLoadingLabel.cpp
        src/widgets/QCollapseToolButton.cpp
        src/delegates/HtmlDelegate.cpp
        src/exceptions/ImageNotSupportedException.cpp
        src/exceptions/ImageTooBigException.cpp
        src/dialogs/PreferencesDialog.cpp
        src/network/NetworkOperations.cpp
        src/dialogs/UsageStatsDialog.cpp
        src/dialogs/AdvancedImportDialog.cpp
        src/services/Importer.cpp
        src/filters/QSliderScrollFilter.cpp
)

if (APPLE AND ENABLE_MACOS_UPDATER)
    set(OSX_SOURCES
            src/updater/osx/AutoUpdater.cpp
            src/updater/osx/CocoaInitializer.mm
            src/updater/osx/SparkleAutoUpdater.mm
    )
endif ()

set(UI
        views/MainWindow.ui
        views/AboutDialog.ui
        views/PreferencesDialog.ui
        views/UsageStatsDialog.ui
        views/AdvancedImportDialog.ui
)

# One ordered locale manifest drives both runtime choices and compiled resources.
file(READ "${CMAKE_SOURCE_DIR}/resources/locales.json" LOCALES_JSON)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/resources/locales.json")
string(JSON LOCALE_COUNT LENGTH "${LOCALES_JSON}")
math(EXPR LAST_LOCALE "${LOCALE_COUNT} - 1")
set(TS_FILES)
set(LANGUAGE_RESOURCES "<RCC><qresource prefix=\"/\">")
set(SEEN_LOCALES)
foreach(INDEX RANGE 0 ${LAST_LOCALE})
    string(JSON LOCALE GET "${LOCALES_JSON}" ${INDEX} locale)
    if (LOCALE IN_LIST SEEN_LOCALES)
        message(FATAL_ERROR "Duplicate locale: ${LOCALE}")
    endif ()
    list(APPEND SEEN_LOCALES "${LOCALE}")
    if (NOT LOCALE STREQUAL "default")
        if (NOT EXISTS "${CMAKE_SOURCE_DIR}/resources/i18n/caesium_${LOCALE}.ts")
            message(FATAL_ERROR "Missing translation source for ${LOCALE}")
        endif ()
        list(APPEND TS_FILES "${CMAKE_SOURCE_DIR}/resources/i18n/caesium_${LOCALE}.ts")
        string(APPEND LANGUAGE_RESOURCES "<file alias=\"i18n/caesium_${LOCALE}.qm\">${CMAKE_BINARY_DIR}/i18n/caesium_${LOCALE}.qm</file>")
    endif ()
endforeach()
string(APPEND LANGUAGE_RESOURCES "</qresource></RCC>")
file(WRITE "${CMAKE_BINARY_DIR}/languages.qrc" "${LANGUAGE_RESOURCES}")

set_source_files_properties(${TS_FILES} PROPERTIES OUTPUT_LOCATION ${CMAKE_BINARY_DIR}/i18n)
qt6_add_translation(QM_FILES ${TS_FILES})

set(RESOURCES
        ${CMAKE_BINARY_DIR}/languages.qrc
        resources/resources.qrc)

set(CORE_SOURCES src/models/CImage.cpp src/utils/Utils.cpp src/services/Importer.cpp
    src/widgets/QCaesiumMessageBox.cpp src/services/OutputFiles.cpp src/services/CompressionTask.cpp src/services/CompressionParameters.cpp src/services/ImportTask.cpp src/services/ImageCodec.cpp
    src/exceptions/ImageNotSupportedException.cpp src/exceptions/ImageTooBigException.cpp src/network/NetworkOperations.cpp)
list(REMOVE_ITEM SOURCES ${CORE_SOURCES})

if (WIN32)
    add_executable(${TARGET} WIN32 ${SOURCES} ${UI} ${RESOURCES} ${CAESIUM_ICON} ${QM_FILES})
elseif (APPLE)
    add_executable(${TARGET} MACOSX_BUNDLE ${SOURCES} ${OSX_SOURCES} ${UI} ${RESOURCES} ${CAESIUM_ICON} ${QM_FILES})
else ()
    add_executable(${TARGET} ${SOURCES} ${OSX_SOURCES} ${UI} ${RESOURCES} ${CAESIUM_ICON} ${QM_FILES})
    install(TARGETS ${TARGET} RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
    if (NOT LIBCAESIUM)
        install(
                FILES ${LIBCAESIUM_SOURCE_DIR}/target/${LIBCAESIUM_BUILD_TYPE}/libcaesium.so
                DESTINATION ${CMAKE_INSTALL_LIBDIR}
        )

    endif ()
endif ()

# --- libcaesium ---
if (CMAKE_BUILD_TYPE MATCHES Debug)
    set(CARGO_BUILD_FLAGS "")
else ()
    set(CARGO_BUILD_FLAGS "--release")
endif ()

set(CARGO_TARGET "")
if (WIN32)
    set(CARGO_TARGET "--target=x86_64-pc-windows-gnu")
    set(LIBCAESIUM_EXTERNAL_PATH ${LIBCAESIUM_SOURCE_DIR}/target/x86_64-pc-windows-gnu/${LIBCAESIUM_BUILD_TYPE}/caesium.dll)
elseif (APPLE)
    set(LIBCAESIUM_EXTERNAL_PATH ${LIBCAESIUM_SOURCE_DIR}/target/${LIBCAESIUM_BUILD_TYPE}/libcaesium.dylib)
else ()
    set(LIBCAESIUM_EXTERNAL_PATH ${LIBCAESIUM_SOURCE_DIR}/target/${LIBCAESIUM_BUILD_TYPE}/libcaesium.so)
endif ()

if (NOT LIBCAESIUM)
    ExternalProject_Add(
            libcaesium
            GIT_REPOSITORY https://github.com/Lymphatus/libcaesium
            GIT_TAG ${LIBCAESIUM_VERSION}
            CONFIGURE_COMMAND ""
            BUILD_COMMAND ${CARGO} build ${CARGO_BUILD_FLAGS} ${CARGO_TARGET}
            INSTALL_COMMAND ""
            BINARY_DIR ${LIBCAESIUM_SOURCE_DIR}
            LOG_OUTPUT_ON_FAILURE ON
            LOG_BUILD ON
            UPDATE_DISCONNECTED TRUE
            BUILD_BYPRODUCTS ${LIBCAESIUM_EXTERNAL_PATH}
    )
    add_dependencies(${TARGET} libcaesium)
endif ()

# --- WinSparkle ---
if (WIN32)
    ExternalProject_Add(
            libwinsparkle
            URL https://github.com/vslavik/winsparkle/releases/download/v0.7.0/WinSparkle-0.7.0.zip
            CONFIGURE_COMMAND ""
            BUILD_COMMAND ""
            INSTALL_COMMAND cmake -E echo "Skipping install step."
            LOG_DOWNLOAD OFF
            LOG_OUTPUT_ON_FAILURE ON
            DOWNLOAD_EXTRACT_TIMESTAMP ON
    )
    add_dependencies(caesium_image_compressor libwinsparkle)
endif ()
# --- WinSparkle ---

if (APPLE)
    set(OSX_FRAMEWORKS "-framework AppKit -framework Carbon -framework Foundation -framework ApplicationServices")
    if (ENABLE_MACOS_UPDATER)
        list(APPEND OSX_FRAMEWORKS ${SPARKLE_FRAMEWORK})
    endif ()
    set_target_properties(${TARGET} PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist" LINK_FLAGS "-F/Library/Frameworks -Wl -rpath @loader_path/../Frameworks")
endif ()

set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME "Caesium Image Compressor")
if (APPLE)
    target_link_libraries(${TARGET} PRIVATE Qt${QT_VERSION_MAJOR}::Widgets Qt${QT_VERSION_MAJOR}::Core Qt${QT_VERSION_MAJOR}::Gui Qt${QT_VERSION_MAJOR}::Concurrent Qt${QT_VERSION_MAJOR}::Svg Qt${QT_VERSION_MAJOR}::Network ${OSX_FRAMEWORKS})
elseif (WIN32)
    target_link_libraries(${TARGET} PRIVATE Qt${QT_VERSION_MAJOR}::Widgets Qt${QT_VERSION_MAJOR}::Core Qt${QT_VERSION_MAJOR}::Gui Qt${QT_VERSION_MAJOR}::Concurrent Qt${QT_VERSION_MAJOR}::Svg Qt${QT_VERSION_MAJOR}::Network winsparkle)
else ()
    set_target_properties(${TARGET} PROPERTIES OUTPUT_NAME "caesium-image-compressor" INSTALL_RPATH "$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")
    target_link_libraries(${TARGET} PRIVATE Qt${QT_VERSION_MAJOR}::Widgets Qt${QT_VERSION_MAJOR}::Core Qt${QT_VERSION_MAJOR}::Gui Qt${QT_VERSION_MAJOR}::Concurrent Qt${QT_VERSION_MAJOR}::Svg Qt${QT_VERSION_MAJOR}::Network)

endif ()

add_library(caesium_core STATIC ${CORE_SOURCES})
target_include_directories(caesium_core PUBLIC src src/include)
option(ENABLE_HEIF "Enable AVIF/HEIC codecs" ${APPLE})
if (ENABLE_HEIF)
    find_package(libheif 1.23.6 EXACT CONFIG REQUIRED)
    find_package(exiv2 0.28.9 CONFIG REQUIRED)
    target_compile_definitions(caesium_core PUBLIC CAESIUM_WITH_HEIF CAESIUM_WITH_METADATA)
    target_link_libraries(caesium_core PUBLIC heif exiv2lib)
endif ()
target_link_libraries(caesium_core PUBLIC Qt6::Widgets Qt6::Concurrent Qt6::Svg Qt6::Network)
if (LIBCAESIUM)
    target_link_libraries(caesium_core PUBLIC ${LIBCAESIUM})
elseif (WIN32)
    target_link_libraries(caesium_core PUBLIC ${LIBCAESIUM_EXTERNAL_PATH})
else ()
    target_link_libraries(caesium_core PUBLIC caesium)
endif ()
if (TARGET libcaesium)
    add_dependencies(caesium_core libcaesium)
endif ()
target_link_libraries(${TARGET} PRIVATE caesium_core)
if (APPLE)
    option(ENABLE_MACOS_NATIVE_UI "Build the SwiftUI/AppKit macOS interface alongside the Qt rollback UI" OFF)
    if (ENABLE_MACOS_NATIVE_UI)
        add_subdirectory(macos)
    endif ()
endif ()
if (BUILD_TESTING)
    add_subdirectory(tests)
endif ()

if (WIN32 AND NOT LIBCAESIUM)
    add_custom_command(TARGET ${TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LIBCAESIUM_EXTERNAL_PATH}" "$<TARGET_FILE_DIR:${TARGET}>")
    if (BUILD_TESTING)
        add_custom_command(TARGET CsTests POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${LIBCAESIUM_EXTERNAL_PATH}" "$<TARGET_FILE_DIR:CsTests>")
    endif ()
endif ()
if (WIN32)
    add_custom_command(TARGET ${TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "${WINSPARKLE_LIB_DIR}/WinSparkle.dll" "$<TARGET_FILE_DIR:${TARGET}>")
endif ()
