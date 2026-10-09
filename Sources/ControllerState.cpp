#include "ControllerState.h"
#include <sstream>

namespace Wolverine {
static int16_t signedLE(const uint8_t *p) {
    const uint16_t bits = uint16_t(p[0]) | (uint16_t(p[1]) << 8);
    const int32_t value = bits >= 0x8000 ? int32_t(bits) - 65536 : bits;
    return static_cast<int16_t>(value);
}
bool decodePacket(const uint8_t *bytes, size_t length, X360State &state) {
    if (!bytes || length < 20 || bytes[0] != 0 || bytes[1] != 20) return false;
    X360State next;
    next.buttons = uint16_t(bytes[2]) | (uint16_t(bytes[3]) << 8);
    next.leftTrigger = bytes[4];
    next.rightTrigger = bytes[5];
    next.lx = signedLE(bytes + 6);
    next.ly = signedLE(bytes + 8);
    next.rx = signedLE(bytes + 10);
    next.ry = signedLE(bytes + 12);
    state = next;
    return true;
}
std::string describeState(const X360State &s) {
    static const struct { uint16_t bit; const char *name; } names[] = {
        {Up,"Up"}, {Down,"Down"}, {Left,"Left"}, {Right,"Right"},
        {Start,"Menu"}, {Back,"View"}, {LeftStick,"L3"}, {RightStick,"R3"},
        {LeftBumper,"LB"}, {RightBumper,"RB"}, {Guide,"Guide"},
        {A,"A"}, {B,"B"}, {X,"X"}, {Y,"Y"}
    };
    std::ostringstream out;
    out << "Buttons:";
    bool any = false;
    for (const auto &name : names) if (s.buttons & name.bit) {
        out << ' ' << name.name; any = true;
    }
    if (!any) out << " none";
    out << "\nLeft stick: " << s.lx << ", " << s.ly;
    out << "\nRight stick: " << s.rx << ", " << s.ry;
    out << "\nTriggers: " << unsigned(s.leftTrigger) << ", " << unsigned(s.rightTrigger);
    return out.str();
}
}
