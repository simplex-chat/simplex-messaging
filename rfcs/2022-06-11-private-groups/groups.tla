---- MODULE groups ----

EXTENDS Naturals, FiniteSets

CONSTANTS
    Users,
    \* The user that starts the group orchestrates all proposals for changes in
    \* membership.  Typically, we would want to avoid a central entity as an
    \* orchestrator, due to the lack of fault tolerance.  However, this
    \* algorithm can only succeed with participation of all parties, since we
    \* need to prove that all members are already directly connected to the
    \* newly invited user.  A predetermined leader simplifies the algorithm
    \* without a loss of fault tolerance.
    Leader,
    Nothing,
    (*
    This function describes indirect perceptions about contact descriptions.
    We can translate "user_percetions[userA, userB, userC] = userD" into the
    english statement: "userA thinks that when userB describes userC they are
    referring to userD."  It's possible that userA knows the correct answer
    (userD = userC), they don't know who userB is talking about (userD =
    Nothing) or they mistake userC for someone else (userD /= Nothing /\ userD
    /= userC).
    *)
    UserPerceptions,
    Connections,
    \* Request Type
    Propose,
    Invite,
    Accept,
    SyncToken

VARIABLES
    messages,
    rng_state,
    group_perceptions,
    proposal,
    tokens

ASSUME
    /\ Leader \in Users
    /\ UserPerceptions \in [ Users \X Users \X Users -> Users \union { Nothing } ]
    \* A user always correctly knows their own perceptions
    /\ \A user1, user2 \in Users : UserPerceptions[<<user1, user1, user2>>] = user2
    /\ Connections \in [ Users -> SUBSET Users ]

InviteIds == Nat

HasDirectConnection(x, y) ==
    \/ x = y
    \/ x \in Connections[y]
    \/ y \in Connections[x]

Init ==
    /\ messages = {}
    /\ rng_state = 0
    (*
    Notably, group members learn about the changes to the group at different
    times, so we need to track their changes in perception individually.
    The empty set means the user doesn't believe themselves to be part of the
    group (they might actually know who some members are).
    *)
    /\ group_perceptions = [ [ x \in Users |-> {} ] EXCEPT ![Leader] = { Leader } ]
    /\ proposal = Nothing
    /\ tokens = [ x \in (InviteIds \X Users) |-> Nothing ]

SendPropose ==
    \E proposer \in Users, invitee \in Users :
        /\ proposer \in group_perceptions[proposer]
        /\ invitee \notin group_perceptions[proposer]
        /\ HasDirectConnection(proposer, invitee)
        \* TODO: This can't really all be atomic
        /\ messages' = messages \union
            {   [ type |-> Propose
                , sender |-> proposer
                , recipient |-> Leader
                , invite_id |-> rng_state
                , invitee |-> invitee
                ]
            }
        /\ rng_state' = rng_state + 1
        /\ UNCHANGED <<group_perceptions, proposal, tokens>>

LeaderReceiveProposal ==
    \E message \in messages :
        /\ message.type = Propose
        /\ message.recipient = Leader
        \* The Leader will kill the proposal immediately if they don't think
        \* they know the invitee, or don't have a direct connection.
        \* UNDERSPECIFIED: In this spec, the message is permanently ignored,
        \* since perceptions never change, which is sufficient to validate our
        \* key properties.  In reality, we need to capture that the proposal is
        \* completed and notify the proposer that the action failed.
        /\ UserPerceptions[<<Leader, message.sender, message.invitee>>] /= Nothing
        \* The Leader is always up to date, this is invariant for all other
        \* members
        /\ UserPerceptions[<<Leader, message.sender, message.invitee>>] \notin group_perceptions[Leader]
        /\ HasDirectConnection(Leader, UserPerceptions[<<Leader, message.sender, message.invitee>>])
        /\ proposal = Nothing
        /\ proposal' =
            [ invite_id |-> message.invite_id
            \* What's being stored isn't really the actual user, but a
            \* description of them by the proposer.
            \* To avoid too many levels of weirdness, this is who the
            \* proposer's intention, not who the leader thinks this is.  The
            \* leader will still send the invite who they _think_ this is, not
            \* necessarily who the proposer intended.
            , invitee |-> message.invitee
            , proposer |-> message.sender
            , group_size |-> Cardinality(group_perceptions[Leader])
            ]
        /\ tokens' = [ tokens EXCEPT ![<<message.invite_id, Leader>>] = rng_state ]
        \* TODO: This can't actually be atomic
        /\ messages' = messages \union
            {   [ type |-> Invite
                , sender |-> Leader
                , recipient |-> UserPerceptions[<<Leader, message.sender, message.invitee>>]
                , invite_id |-> message.invite_id
                , token |-> rng_state
                , group_size |-> proposal'.group_size
                ]
            }
        /\ rng_state' = rng_state + 1
        /\ UNCHANGED <<group_perceptions>>

RebroadcastProposal ==
    \E member \in (Users \ { Leader }) :
        /\ proposal /= Nothing
        /\ member /= proposal.proposer
        /\ member \in group_perceptions[Leader]
        /\ messages' = messages \union
            {   [ sender |-> Leader
                , recipient |-> member
                , type |-> Propose
                , invite_id |-> proposal.invite_id
                , invitee |-> proposal.invitee
                , proposer |-> proposal.proposer
                , group_size |-> proposal.group_size
                ]
            }
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, tokens>>

ApproverReceiveProposal ==
    \E message \in messages :
        /\ message.type = Propose
        /\ message.recipient /= Leader
        \* UNDERSPECIFIED: The member ignores the message permanently if these
        \* guards fail.  Realistically, they need to notify the Leader that the
        \* proposal is doomed.
        /\ UserPerceptions[<<message.recipient, message.proposer, message.invitee>>] /= Nothing
        /\ HasDirectConnection(message.sender, UserPerceptions[<<message.recipient, message.proposer, message.invitee>>])
        /\ tokens' = [ tokens EXCEPT ![<<message.invite_id, message.recipient>>] = rng_state ]
        \* It's safe to send this message right away, as it only agrees to
        \* reveal information that everyone has agreed to share.  The invitee
        \* now knows that there's a group that involves this member, the
        \* proposer, and any other members that have sent this message, giving
        \* the invitee insight into how these contacts are all connected.
        \* However, that is exactly what they all just agreed to.  Members that
        \* don't agree to send this message remain private.
        /\ messages' = messages \union
            {   [ sender |-> message.recipient
                , recipient |-> UserPerceptions[<<message.recipient, message.proposer, message.invitee>>]
                , type |-> Invite
                , invite_id |-> message.invite_id
                , token |-> rng_state
                , group_size |-> message.group_size \* TODO: Invariant that all Invites of the same invite_id have the same group size
                ]
            }
        /\ rng_state' = rng_state + 1
        /\ UNCHANGED <<group_perceptions, proposal>>

BroadcastToken ==
    \E from \in Users, invite_id \in InviteIds :
        \E to \in (group_perceptions[from] \ { from }) :
            /\ tokens[<<invite_id, from>>] /= Nothing
            /\ messages' = messages \union
                {   [ sender |-> from
                    , recipient |-> to
                    , type |-> SyncToken
                    , token |-> tokens[<<invite_id, from>>]
                    , invite_id |-> invite_id
                    ]
                }
            /\ UNCHANGED <<rng_state, group_perceptions, proposal, tokens>>

\* IMPORTANT: It is NOT inviariant that the invitee matches across the same
\* invite_id, because some members may have confused the invitee.
GetInvites(invite_id, invitee) ==
    { message \in messages : message.type = Invite /\ message.recipient = invitee /\ message.invite_id = invite_id }

SendAccept ==
    \E message \in messages :
        /\ message.type = Invite
        /\ LET  invitee == message.recipient
                invite_id == message.invite_id
                Invites == GetInvites(invite_id, invitee)
                Inviters == { invite.sender : invite \in Invites }
                Tokens == { invite.token : invite \in Invites }
           IN   IF   Cardinality(Inviters) = message.group_size
                THEN
                    \E member \in Inviters :
                        \* IMPORTANT: The Accept may still has a chance of
                        \* being ignored (or token mismatch or something odd),
                        \* so the invitee does not yet believe themself to be
                        \* part of the group.  At least one member must
                        \* establish a connection with them first.
                        /\ messages' = messages \union
                            {   [ sender |-> invitee
                                , recipient |-> member
                                , type |-> Accept
                                , tokens |-> Tokens
                                , invite_id |-> invite_id
                                ]
                            }
                ELSE UNCHANGED <<messages>>
        /\ UNCHANGED <<rng_state, group_perceptions, proposal, tokens>>

Establish ==
    \E message \in messages :
        /\ message.type = Accept
        /\ LET SyncMessages == { sync \in messages : sync.recipient = message.recipient /\ sync.type = SyncToken /\ sync.invite_id = message.invite_id }
               Senders == { sync.sender : sync \in SyncMessages }
               Tokens == { sync.token : sync \in SyncMessages } \union { tokens[<<message.invite_id, message.recipient>>] }
           IN  /\ Senders = (group_perceptions[message.recipient] \ { message.recipient })
               /\ message.tokens = Tokens
               \* TODO: This can't be atomic
               /\ group_perceptions' =
                   [ group_perceptions
                   EXCEPT ![message.recipient] = @ \union { message.sender }
                   \* If this is the first member to establish, the invitee
                   \* now knows they are in the group with everyone who
                   \* invited them
                   , ![message.sender] =
                       IF @ = {}
                       THEN { invite.sender : invite \in GetInvites(message.invite_id, message.sender) } \union { message.sender }
                       ELSE @
                   ]
               /\ proposal' =
                   IF  /\ proposal /= Nothing
                       /\ proposal.invite_id = message.invite_id
                       /\ message.recipient = Leader
                   THEN Nothing
                   ELSE proposal
               /\ UNCHANGED <<messages, rng_state, tokens>>

\* TODO: Leader needs to rememmber completed proposals so they don't do them
\* again (kick, add, kick, add, ...)

\* TODO: Members should notify the Leader when the proposal is doomed so they
\* drop it

\* TODO: It is impossible to tell if a proposal is doomed because of invitee
\* confusion or if the invitation is just taking time, as such, the Leader
\* needs to be able to cancel invitations.  We need this in two stages, one to
\* Hold (continue, but do not establish) and then the other to Resume (if
\* someone _did_ establish, meaning the action is committed) or Cancel (if no
\* one has).

\* TODO: Need to be able to Kick.  Notably, this is easier, because we don't
\* need to confirm identities.

\* TODO: Need to be able to kick users who are preventing progress in an
\* invitation.  Any user who is not responding to a Hold is safely kickable.
\* In the worst case, the kicked user(s) did establish a connection with the
\* invitee, meaning the kicked and invitee still think they are part of the
\* group, even though they've been kicked out.  Ideally, they can eventually
\* learn that they are kicked out.  Once kicked, it's safe to send a Cancel
\* message to all other members.  In fact, the kicked members can be
\* piggy-backed on the Cancel message.  Then new invites can be sent.


Next ==
    \/ SendPropose
    \/ LeaderReceiveProposal
    \/ RebroadcastProposal
    \/ ApproverReceiveProposal
    \/ BroadcastToken
    \/ SendAccept
    \/ Establish

Spec == Init /\ [][Next]_<<messages, rng_state, group_perceptions, proposal, tokens>>


CannotCommunicateWithoutAConnection ==
    \A message \in messages :
        HasDirectConnection(message.sender, message.recipient)

\* An other that receives two invites which share an invite id, knows that
\* these two contacts know each other and that they are in a group together
\* with N people.
\* TODO
KnowsTwoMembersKnowEachOther(other, member1, member2) ==
    TRUE

\* TODO
OthersOnlyKnowMembersKnowEachOtherIfMembersAcceptedProposal ==
    TRUE

\* TODO
MembersOnlyEstablishWithInvitee ==
    TRUE

\* TODO
EstablishedOnlyIfAllPerceptionsMatch ==
    TRUE

====
