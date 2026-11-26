// Opt-in diagnostic A/B only: a foreground, authenticated LAN session on the
// owning reader thread. Never touch a process, another thread, or a system setting.
#include <qos/qos.h>
extern "C" int sesame_reader_restore_qos(int old) {
    return old < 0 ? OH_QoS_ResetThreadQoS() : OH_QoS_SetThreadQoS(static_cast<QoS_Level>(old));
}
extern "C" int sesame_reader_begin_qos(int* previous) {
    QoS_Level current{};
    const bool known=OH_QoS_GetThreadQoS(&current)==0;
    if (known && (current < QOS_BACKGROUND || current > QOS_USER_INTERACTIVE)) return 5;
    *previous=known ? static_cast<int>(current) : -1;
    if (known && current>=QOS_USER_INITIATED) return current==QOS_USER_INITIATED ? 2 : 3;
    if (OH_QoS_SetThreadQoS(QOS_USER_INITIATED)!=0) return 4;
    if (OH_QoS_GetThreadQoS(&current)==0 && current==QOS_USER_INITIATED) return 1;
    sesame_reader_restore_qos(*previous);
    return 5;
}
