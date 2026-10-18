#include "connection_deadline.h"
#include <cassert>
#include <iostream>

int main() {
    using namespace ConnectionDeadline;
    assert(evaluate(0, 0, 90000) == Expired::None);
    assert(evaluate(1000, 0, 30999) == Expired::None);
    assert(evaluate(1000, 0, 31000) == Expired::Transport);
    // Reproduce the report: relay ready at 13s must survive the old 30s cutoff.
    assert(evaluate(1000, 14000, 31000) == Expired::None);
    assert(evaluate(1000, 14000, 43999) == Expired::None);
    assert(evaluate(1000, 14000, 44000) == Expired::Login);
    // Near-deadline transport still gets a full, bounded login window.
    assert(evaluate(1000, 28999, 58998) == Expired::None);
    assert(evaluate(1000, 28999, 58999) == Expired::Login);
    assert(evaluate(1000, 50000, 61000) == Expired::Total);
    // A completed/cancelled session has no active deadline; a new attempt starts fresh.
    assert(evaluate(0, 14000, 100000) == Expired::None);
    assert(evaluate(100000, 0, 100001) == Expired::None);
    // Submitting 2FA starts another response budget without including user input time.
    assert(evaluate(200000, 200000, 229999) == Expired::None);
    assert(evaluate(200000, 200000, 230000) == Expired::Login);
    std::cout << "PASS production connection deadlines: slow relay, transport/login budgets, total cap, cancellation and 2FA\n";
}
