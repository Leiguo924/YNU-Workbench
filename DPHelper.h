#pragma once
#include <stddef.h>
#include <stdint.h>
int dp_helper_acquire(const char *address, uint8_t routes, char *name, size_t capacity);
int dp_helper_acquire_hosts(const char *address, uint8_t routes, const char *hosts, char *name, size_t capacity);
