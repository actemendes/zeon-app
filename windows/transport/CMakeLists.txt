cmake_minimum_required(VERSION 3.14)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(zeon_windows_transport LANGUAGES CXX)
endif()

add_library(zeon_windows_transport SHARED
  "zeon_windows_websocket.cpp"
  "zeon_windows_websocket.h"
)

target_compile_features(zeon_windows_transport PUBLIC cxx_std_17)
target_compile_definitions(zeon_windows_transport PRIVATE
  UNICODE
  _UNICODE
  WIN32_LEAN_AND_MEAN
  NOMINMAX
  ZEON_WINDOWS_TRANSPORT_EXPORTS
)
target_compile_options(zeon_windows_transport PRIVATE /W4 /WX /EHsc /sdl)
target_link_options(zeon_windows_transport PRIVATE
  $<$<CONFIG:Release>:/DYNAMICBASE>
  $<$<CONFIG:Release>:/NXCOMPAT>
  $<$<CONFIG:Release>:/HIGHENTROPYVA>
  $<$<CONFIG:Release>:/guard:cf>
  $<$<CONFIG:Release>:/CETCOMPAT>
)
target_link_libraries(zeon_windows_transport PRIVATE winhttp.lib)
