#include "../src/protocol.h"
#include <cassert>
#include <iostream>
int main() {
    using namespace nativos;
    assert(parse("NATIVOS/1 PREPARE\n") == Command::Prepare);
    assert(parse("NATIVOS/1 STATUS\n") == Command::Status);
    assert(parse("NATIVOS/1 START\n") == Command::Start);
    assert(parse("NATIVOS/1 STOP\n") == Command::Stop);
    DisplaySize size;
    assert(displaySize("NATIVOS/1 START 1080 2400\n", size));
    assert(size.width == 1080 && size.height == 2400);
    assert(parse("NATIVOS/1 START 2400 1080\n") == Command::Start);
    for (auto input : {"NATIVOS/1 START 0 2400\n", "NATIVOS/1 START 1080 99999\n",
                       "NATIVOS/1 START 01080 2400\n", "NATIVOS/1 START -1 2400\n",
                       "NATIVOS/1 START 1080 2400;id\n", "NATIVOS/1 START 1080 2400 \n",
                       "NATIVOS/1 START 8192 8192\n", "NATIVOS/1 START 1080 2400\r\n"}) {
        assert(parse(input) == Command::Invalid);
        assert(!displaySize(input, size));
    }
    for (auto input : {"START\n", "NATIVOS/2 START\n", "NATIVOS/1 START /data/x\n",
                       "NATIVOS/1 EXEC id\n", "NATIVOS/1 START;id\n", "NATIVOS/1 START\r\n", ""}) {
        assert(parse(input) == Command::Invalid);
    }
    assert(authorized(10042, "u:r:nativos_app:s0:c42,c256,c512,c768"));
    assert(!authorized(10042, "u:r:priv_app:s0"));
    assert(!authorized(10042, "u:r:nativos_app_other:s0"));
    assert(!authorized(10042, "u:r:nativos_app:s00"));
    assert(!authorized(0, "u:r:nativos_app:s0"));
    assert(!authorized(2000, "u:r:nativos_app:s0"));
    assert(!authorized(110042, "u:r:nativos_app:s0"));
    std::cout << "Protocol/authentication boundary tests passed\n";
}
