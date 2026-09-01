cmake_minimum_required(VERSION 3.20)
project(usb16x16_rt_bridge VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(usb16x16_bridge_core
    src/bridge_core.cpp
)
target_include_directories(usb16x16_bridge_core PUBLIC include)
target_compile_options(usb16x16_bridge_core PRIVATE -Wall -Wextra -Wpedantic -Werror)

include(CTest)
if(BUILD_TESTING)
    add_executable(usb16x16_bridge_tests tests/bridge_tests.cpp)
    target_link_libraries(usb16x16_bridge_tests PRIVATE usb16x16_bridge_core)
    target_compile_options(usb16x16_bridge_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME bridge_core COMMAND usb16x16_bridge_tests)
endif()

find_path(ALSA_INCLUDE_DIR alsa/asoundlib.h)
find_library(ALSA_LIBRARY NAMES asound)

if(ALSA_INCLUDE_DIR AND ALSA_LIBRARY)
    add_executable(usb16x16-rt-bridge src/main.cpp)
    target_include_directories(usb16x16-rt-bridge SYSTEM PRIVATE ${ALSA_INCLUDE_DIR})
    target_link_libraries(usb16x16-rt-bridge
        PRIVATE usb16x16_bridge_core ${ALSA_LIBRARY} pthread)
    target_compile_options(usb16x16-rt-bridge PRIVATE -Wall -Wextra -Wpedantic -Werror)
    install(TARGETS usb16x16-rt-bridge RUNTIME DESTINATION bin)
else()
    message(STATUS "ALSA development files not found; building core tests only")
endif()
