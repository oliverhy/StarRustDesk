#include "../../entry/src/main/cpp/sunshine/narrow_sdp.h"

constexpr bool onlyRepairFloorChanges()
{
    char generated[] = "v=0\r\na=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\na=transport:encrypted \r\n";
    return applyNarrowRepairFloor(generated,sizeof(generated)-1) &&
        std::string_view(generated)=="v=0\r\na=x-nv-vqos[0].fec.minRequiredFecPackets:1 \r\na=transport:encrypted \r\n";
}

constexpr bool duplicateFailsBeforeEdit()
{
    char generated[] = "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n"
                       "a=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n";
    return !applyNarrowRepairFloor(generated,sizeof(generated)-1) &&
        std::string_view(generated).find(":1 ") == std::string_view::npos;
}

constexpr bool unknownVersionFailsBeforeEdit()
{
    char generated[] = "a=x-nv-vqos[0].fec.minRequiredFecPackets:3 \r\n";
    char absent[] = "a=x-nv-vqos[0].fec.mode:2 \r\n";
    return !applyNarrowRepairFloor(generated,sizeof(generated)-1) &&
           !applyNarrowRepairFloor(absent,sizeof(absent)-1) &&
           std::string_view(generated).find(":3 ") != std::string_view::npos;
}

static_assert(onlyRepairFloorChanges());
static_assert(duplicateFailsBeforeEdit());
static_assert(unknownVersionFailsBeforeEdit());
