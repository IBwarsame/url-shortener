#!/bin/bash
# Runs inside LocalStack once it is ready. Creates the click-events queue.
set -euo pipefail
awslocal sqs create-queue --queue-name click-events
