#pragma once
#include <string>
class SoSeparator;
namespace cadnext::gui {
// Same authored USDZ as UAVsim, metres, Y up, nose +Z. Static inspection pose.
SoSeparator* loadUAVUSDZ(const std::string& path, std::string& error);
}
