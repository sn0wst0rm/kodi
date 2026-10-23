set(SOURCES IOSEAGLView.mm
            IOSVideoCompositor.mm
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

# Keep per-pixel subtitle composition efficient in device Debug builds too.
# Debug symbols remain enabled; no GPU work is submitted by this helper.
set_source_files_properties(IOSVideoCompositor.mm PROPERTIES COMPILE_OPTIONS "-O2")

core_add_library(platform_ios)
