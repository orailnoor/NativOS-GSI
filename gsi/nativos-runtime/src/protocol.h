#pragma once
#include <string_view>
#include <sys/types.h>

namespace nativos {
enum class Command { Prepare, Status, Start, Stop, Invalid };
struct DisplaySize { unsigned width = 1024, height = 768; };
inline bool displaySize(std::string_view request, DisplaySize& result) {
    constexpr std::string_view prefix = "NATIVOS/1 START ";
    if (request.size() <= prefix.size() || request.substr(0, prefix.size()) != prefix
        || request.back() != '\n') return false;
    auto numbers = request.substr(prefix.size(), request.size() - prefix.size() - 1);
    auto separator = numbers.find(' ');
    if (separator == std::string_view::npos) return false;
    auto number = [](std::string_view text, unsigned& output) {
        if (text.empty() || text.size() > 4 || text.front() == '0') return false;
        unsigned value = 0;
        for (char digit : text) {
            if (digit < '0' || digit > '9') return false;
            value = value * 10 + static_cast<unsigned>(digit - '0');
        }
        if (value < 240 || value > 8192) return false;
        output = value;
        return true;
    };
    DisplaySize candidate;
    if (!number(numbers.substr(0, separator), candidate.width)
        || !number(numbers.substr(separator + 1), candidate.height)
        || candidate.width * candidate.height > 16777216) return false;
    result = candidate;
    return true;
}
inline Command parse(std::string_view request) {
    if (request == "NATIVOS/1 PREPARE\n") return Command::Prepare;
    if (request == "NATIVOS/1 STATUS\n") return Command::Status;
    if (request == "NATIVOS/1 START\n") return Command::Start;
    if (request == "NATIVOS/1 STOP\n") return Command::Stop;
    DisplaySize dimensions;
    if (displaySize(request, dimensions)) return Command::Start;
    return Command::Invalid;
}
inline bool authorized(uid_t uid, std::string_view context) {
    if (uid < 10000 || uid > 19999) return false;
    constexpr std::string_view base = "u:r:nativos_app:s0";
    if (context == base) return true;
    // SO_PEERSEC is kernel-supplied, not a client-provided string.
    return context.size() > base.size() && context.substr(0, base.size()) == base
        && context[base.size()] == ':';
}
}
