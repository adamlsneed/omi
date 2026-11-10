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
        const int omi_assert_true_value_ = !!(result);                                                                 \
        if (!omi_assert_true_value_) {                                                                                 \
            LOG_ERR("Error at %s:%d:%d", __FILE__, __LINE__, omi_assert_true_value_);                                  \
            return -1;                                                                                                 \
        }                                                                                                              \
    } while (0)

#endif
