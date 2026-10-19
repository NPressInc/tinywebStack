#!/usr/bin/env bash
systemctl restart synapse 2>/dev/null || systemctl restart matrix-synapse
