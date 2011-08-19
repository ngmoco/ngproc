ngproc - A distributed process registry.
=================================================

``ngproc`` is a distributed process registry that performs the same
essential functions as ``global``. It provides a user-specified
conflict resolution callback in a similar fashion to ``global``.

To provide lower call latency, it uses a distinguished master node
(dynamically elected using gl_async_bully) to decide the outcome of
registry operations. This allows ngproc to offer faster and more
consistent call times than global, which employs a more complicated
and less deterministic protocol.

Features
--------

- Distributed process registration using any term as a key
- User specified conflict resolution
- Distributed leader election
- OTP application and configuration
- Builds with rebar

Current Limitations
-------------------

- All nodes in the network must be known at boot time.
  
  The underlying leader election system gl_async_bully requires each
  node to know all other nodes in the network. No API is provided to
  change this set of nodes once the registry starts.

  This limitation is on the road-map to fix, in the meantime, either
  forcibly adjust the leader election state to add nodes while they're
  running, or add node names ahead of time. There's no great penalty
  to running with 'DOWN' nodes.

Installation
------------

Building ngproc
_____________

Prerequisites:
- Erlang R14B+
- rebar

#. rebar get-deps compile
#. enjoy a well earned margarita

