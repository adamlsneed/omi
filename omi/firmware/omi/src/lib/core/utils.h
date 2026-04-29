#ifndef UTILS_H
#define UTILS_H

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/logging/log.h>

#define ASSERT_OK(result)                                                                                              \
    do {                                                                                                               \
        int _result = (result);                                                                                        \
        if (_result < 0) {                                                                                             \
            LOG_ERR("Error at %s:%d:%d", __FILE__, __LINE__, _result);                                                 \
            return _result;                                                                                            \
        }                                                                                                              \
    } while (0)

#define ASSERT_TRUE(result)                                                                                            \
    do {                                                                                                               \
        int _result = (result);                                                                                        \
        if (!_result) {                                                                                                \
            LOG_ERR("Error at %s:%d:%d", __FILE__, __LINE__, _result);                                                 \
            return -1;                                                                                                 \
        }                                                                                                              \
    } while (0)

#endif
