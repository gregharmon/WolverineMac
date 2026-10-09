#include "ControllerState.h"
#include <array>
#include <cstdio>
#include <cstdlib>
using namespace Wolverine;
static void require(bool ok, const char *message) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
int main() {
    std::array<uint8_t, 20> p{};
    p[1] = 20;
    X360State state;
    require(decodePacket(p.data(),p.size(),state),"neutral input accepted");
    require(state.buttons == 0 && state.lx == 0 && state.rightTrigger == 0,"neutral state");
    p[2] = 0xff; p[3] = 0xf7; p[4] = 0; p[5] = 255;
    p[6] = 0; p[7] = 0x80; // -32768
    p[8] = 0xff; p[9] = 0x7f; // 32767
    p[10] = 0xff; p[11] = 0xff; // -1
    p[12] = 1; p[13] = 0; // 1
    require(decodePacket(p.data(),p.size(),state),"full input accepted");
    require(state.buttons == 0xf7ff,"all standard buttons retained");
    require(state.lx == -32768 && state.ly == 32767 && state.rx == -1 && state.ry == 1,"signed little endian axes");
    require(state.leftTrigger == 0 && state.rightTrigger == 255,"trigger endpoints");
    require(!decodePacket(nullptr,20,state),"null rejected");
    require(!decodePacket(p.data(),19,state),"truncated input rejected");
    p[0] = 1;
    require(!decodePacket(p.data(),p.size(),state),"status packet rejected");
    p[0] = 0; p[1] = 0;
    require(!decodePacket(p.data(),p.size(),state),"wrong advertised length rejected");
    require(state.lx == -32768 && state.buttons == 0xf7ff,"bad packet does not clear held input");
    std::puts("Controller packet checks passed.");
}
