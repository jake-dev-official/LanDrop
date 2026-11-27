cmake_minimum_required(VERSION 3.14)
project(landrop_shell_ext LANGUAGES CXX)

add_library(landrop_shell_ext SHARED
  "device_cache_reader.cpp"
  "landrop_shell_ext.cpp"
  "landrop_shell_ext.def"
)

apply_standard_settings(landrop_shell_ext)
target_compile_features(landrop_shell_ext PRIVATE cxx_std_20)
target_compile_definitions(landrop_shell_ext PRIVATE "NOMINMAX")
target_link_libraries(landrop_shell_ext PRIVATE
  "shlwapi.lib"
  "shell32.lib"
  "ole32.lib"
)

add_executable(landrop_shell_ext_test
  "device_cache_reader.cpp"
  "shell_ext_test.cpp"
)

apply_standard_settings(landrop_shell_ext_test)
target_compile_features(landrop_shell_ext_test PRIVATE cxx_std_20)
target_compile_definitions(landrop_shell_ext_test PRIVATE "NOMINMAX")
target_link_libraries(landrop_shell_ext_test PRIVATE
  "ole32.lib"
  "shell32.lib"
)
