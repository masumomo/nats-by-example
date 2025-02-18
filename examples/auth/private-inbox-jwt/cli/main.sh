#!/bin/sh

set -uo pipefail

NATS_URL="${NATS_URL:-nats://localhost:4222}"

# Create the operator, generate a signing key (which is a best practice),
# and initialize the default SYS account and sys user.
nsc add operator --generate-signing-key --sys --name local

# A follow-up edit of the operator enforces signing keys are used for
# accounts as well. Setting the server URL is a convenience so that
# it does not need to be specified with call `nsc push`.
nsc edit operator --require-signing-keys \
  --account-jwt-server-url "$NATS_URL"

# Next we need to create an account intended for application usage. It is
# currently a two-step process to create the account, followed by
# generating the signing key.
nsc add account APP
nsc edit account APP --sk generate

# This command generates the bit of configuration to be used by the server
# to setup the embedded JWT resolver.
nsc generate config --nats-resolver --sys-account SYS > resolver.conf

# Create the most basic config that simply include the generated
# resolver config.
cat <<- EOF > server.conf
include resolver.conf
EOF

# Start the server.
nats-server -c server.conf 2> /dev/null &
SERVER_PID=$!

sleep 1

# Push the account up to the server.
nsc push -a APP

# Next we will create three users. The first one called `greeter` will
# be used for the `greet` service. It can subscribe to a dedicated
# subject in order to service requests.
nsc add user --account APP greeter \
  --allow-sub 'services.greet' \
  --allow-pub-response

# The next two users emulate consumers of the service. They can publish
# on their own prefixed subject as well as publish to services scoped the
# their respective name.
nsc add user --account APP joe \
  --allow-pub 'joe.>' \
  --allow-pub 'services.*'

nsc add user --account APP pam \
  --allow-pub 'pam.>' \
  --allow-pub 'services.*'

# Since we didn't set an explicit allow for subscriptions, these users
# can still subscribe to `>` which means joe could subscribe to `pam.>`
# and vice versa. We do know that in order to receive replies
# from services, we need to subscribe to `_INBOX.>`.
nsc edit user --account APP joe \
  --allow-sub '_INBOX.>'

nsc edit user --account APP pam \
  --allow-sub '_INBOX.>'

# A nice side effect of this is that now, joe and pam can't subscribe
# to each other's subjects, however, what about `_INBOX.>`? Let's observe
# the current behavior and then see how we can address this.

# First, let's save a few contexts for easier reference.
nats context save greeter \
  --nsc nsc://local/APP/greeter

nats context save joe \
  --nsc nsc://local/APP/joe

nats context save pam \
  --nsc nsc://local/APP/pam

# Then we startup the greeter service that simply returns a unique reply ID.
nats --context greeter \
  reply 'services.greet' \
  'Reply {{ID}}' &

GREETER_PID=$!

# Tiny sleep to ensure the service is connected.
sleep 0.5

# Send a greet request from joe and pam.
nats --context joe request 'services.greet' ''
nats --context pam request 'services.greet' ''

# But can pam also receive replies from requests sent by joe? Indeed,
# by subscribing to the inbox.
nats --context pam sub '_INBOX.>' &
INBOX_SUB_PID=$!

# When joe sends a request, the reply will come back to him, but also
# be received by pam. 🤨 This is actually expected and generally fine
# since _accounts_ are expected to be the isolation boundary, at a
# certain level of scale, creating users with granular permissions
# becomes increasingly necessary.
nats --context joe request 'services.greet' ''

# Sinces inboxes are randomly generated by the server, by default we
# can't pin down the specific set of subjects to provide permission to.
# However, as a client, there is the option of defining an explicit
# *inbox prefix* other than `_INBOX`.
nats --context joe --inbox-prefix _INBOX_joe request 'services.greet' ''

# Now that we can have a differentiated inbox prefix, we can deny the
# default one and allow for the custom one.
nsc edit user --account APP joe \
  --deny-sub '_INBOX.>' \
  --allow-sub '_INBOX_joe.>'

nsc edit user --account APP pam \
  --deny-sub '_INBOX.>' \
  --allow-sub '_INBOX_pam.>'

# Stop the previous service to pick up the new permission. Now pam
# cannot subscribe to the general `_INBOX` nor joe's specific one
# since it does not have an explicit allow.
kill $INBOX_SUB_PID
nats --context pam sub '_INBOX.>'
nats --context pam sub '_INBOX_joe.>'

# Now we can send requests and receive replies in isolation.
nats --context joe --inbox-prefix _INBOX_joe request 'services.greet' ''
nats --context pam --inbox-prefix _INBOX_pam request 'services.greet' ''

# Finally stop the service and server.
kill $GREETER_PID
kill $SERVER_PID
