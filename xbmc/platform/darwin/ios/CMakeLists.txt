set(SOURCES IOSEAGLView.mm
            IOSVideoCompositor.mm
            IOSVideoToneMap.mm
            IOSExternalTouchController.mm
            IOSKeyboardView.mm
            IOSScreenManager.mm
            XBMCController.mm)

set(HEADERS IOSEAGLView.h
            IOSExternalTouchController.h
            IOSKeyboardView.h
            IOSScreenManager.h
            XBMCApplication.h
            XBMCController.h)

core_add_library(platform_ios)

# The monolithic iOS target is created in the root directory; attach source
# options there as well as in the standalone-library configuration.
set_source_files_properties("${CMAKE_CURRENT_SOURCE_DIR}/IOSVideoCompositor.mm"
                           TARGET_DIRECTORY ${CORE_LIBRARY}
                           PROPERTIES COMPILE_OPTIONS "-O2")
