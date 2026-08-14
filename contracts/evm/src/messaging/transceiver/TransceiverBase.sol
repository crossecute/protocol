// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {OutboundBase} from "src/messaging/outbound/OutboundBase.sol";
import {Call} from "src/messaging/Call.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Envelope} from "src/messaging/Envelope.sol";
import {ICancel, ICommitFinalize, InboundBase} from "src/messaging/inbound/InboundBase.sol";
import {Erc7930} from "src/addressing/Erc7930.sol";
import {CrossProxy, ICrossProxy} from "src/account/CrossProxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title TransceiverBase
/// @notice Authentication, routing, manufacture, and the upgrade lock: the half that is
///         identical wherever a transceiver is deployed.
///
/// @dev A SPOKE MAKES RECEIVERS. A HUB DOES NOT. Manufacturing lives in
///      `SpokeTransceiverBase`, so a hub does not merely decline to create a receiver: it
///      has no function that could. That matters because a transmitter and its receivers
///      share one address, and an address holds one contract, so a receiver on the home
///      chain would collide with the transmitter that belongs there. Absence beats a revert,
///      because there is no entry point for a later change to expose.
///
/// @dev IT IS AN `InboundBase`, AND THAT IS WHAT MAKES A BOOTSTRAP DEFERRABLE. A bootstrap is
///      the one message whose gas lands on whoever is delivering it rather than on the party
///      that wanted it, and it is the one message an account cannot receive for itself, since
///      the account does not exist yet. So a payload arriving here as `commit(hash)` can be
///      finalized later by anyone willing to pay for it, and `bootstrapInbound` runs as the
///      self-call it already required. What that costs is that a transceiver now executes
///      arrays, which it previously did not: the bar is `InboundBase`'s, one authenticated
///      origin, plus a `_checkCommitter` that admits nothing but this contract itself.
///
/// @dev IT IS STILL NOT A `ReceiverBase`. It holds no `sourceTransmitter`, has no `execute`,
///      and cannot `cancel`: withdrawing an approval on a contract shared by every owner on
///      the chain would let whoever reached the entry point strip a bootstrap somebody else
///      has already paid to send.
///
/// @dev IT HAS NO AUTHORITY AT ALL, AND THAT IS WHAT THE TWO HALVES DISAGREE ABOUT.
///      `Ownable` sits on `HubTransceiverBase`, because the hub is the only half with
///      anything to configure after deployment: a spoke's home, route, counterpart,
///      implementation, and divergence flag are written in its initializer and have no
///      setters, so an owner there would be an authority over nothing. Keeping ownership out
///      of this base makes that structural rather than a matter of the spoke declining to
///      exercise one.
///
/// @dev `TREASURY_ROLE` AND `GATEWAY_ROLE` ARE NOT AUTHORITIES EITHER. They name addresses
///      rather than powers, are fixed in the initializer, and cannot be granted afterwards by
///      anyone: see `Roles.grantRole`.
///
/// @dev A TRANSCEIVER'S TRANSPORTS ARE FIXED IN BOTH DIRECTIONS. It has no revoke entry point
///      either, which an account does have: a transceiver is shared by every owner on its
///      chain, so dropping a gateway here would take every account's bootstrap path with it,
///      while an account's is one owner's to drop. What that costs is that a compromised
///      transport is answered by deploying a new transceiver rather than by a transaction,
///      which is the same remedy the upgrade lock already implies. Naming several gateways up
///      front is how a deployment keeps a migration cheap.
///
/// @dev EVERYTHING ASYMMETRIC IS BEHIND `_counterpartOn` AND `_routeTo`, because the two
///      sides have opposite cardinality: the hub has N counterparts and needs a registry to
///      tell them apart, while a spoke has exactly one and is told which at deployment. So a
///      spoke never carries a registry pointer, a provenance dial, or a routing table it has
///      no use for.
///
/// @dev ONE RECEIVER PER TRANSMITTER, PER DESTINATION. The CREATE2 salt is `(owner, salt)`
///      and nothing else, so an account's address is fixed for the life of the protocol:
///      known before the first message, unchanged after the thousandth. Nothing about the
///      payload is in the salt, which would mint a new receiver per message and throw away
///      the state a receiver accumulates.
abstract contract TransceiverBase is
    Initializable,
    OutboundBase,
    InboundBase,
    ICancel,
    UUPSUpgradeable
{
    /// @notice What a deployment names on EITHER half, and can never revisit: the treasury
    ///         that may be paid, and the transports that may carry messages.
    ///
    /// @dev THE OWNER IS NOT IN HERE, BECAUSE ONLY THE HUB HAS ONE. It is
    ///      `__HubTransceiverBase_init`'s own argument, so a spoke deployment cannot pass an
    ///      owner that would silently govern nothing.
    ///
    /// @dev ONE STRUCT RATHER THAN LOOSE ARGUMENTS, for two reasons. It keeps the divergent
    ///      spokes' initializers under the stack limit, which `paris` without via-IR makes a
    ///      real constraint rather than a style question. And it puts both in one place at
    ///      every layer, so a binding writing an initializer cannot thread one through and
    ///      quietly drop the other.
    struct Deployment {
        address treasury;
        address[] gateways;
    }

    /// Once true, no further implementation change is possible. One-way.
    bool public upgradesLocked;

    /// @notice The initcode hash every crossecute account deploys from: one constant, for
    ///         transmitters and receivers alike.
    /// @dev Exposed so the hub can record it and reproduce these addresses without deploying
    ///      anything. See `CrossProxy` for why it has no constructor arguments.
    /// @dev IT IS AN INPUT TO ETHEREUM'S CREATE2 FORMULA, AND ONLY THAT. A chain that
    ///      derives addresses differently does not consume this value at all, and one that
    ///      also compiles differently (zkSync, whose deploy input is a zksolc artifact hash
    ///      rather than EVM initcode) has no relationship to it. See `predictCrossAccount`.
    bytes32 public constant CROSS_PROXY_INIT_CODE_HASH =
        keccak256(type(CrossProxy).creationCode);

    event UpgradesLocked();
    /// @dev Owner and account are indexed; the salt rides in the data. Three indexed fields
    ///      would exhaust the topic budget for a value nobody filters on: an indexer wants
    ///      "this owner's accounts" or "this address", not "everyone who chose salt 7".
    event CrossAccountCreated(
        address indexed owner, address indexed account, bytes32 salt
    );

    error UpgradesAreLocked();
    error ZeroOwner();
    /// @dev The caller is not the account `(owner, salt)` resolves to, so it is asking the
    ///      protocol to stand up somebody else's account somewhere else.
    error NotTheAccount(address owner, bytes32 salt, address caller);
    error CrossAccountExists(address owner, bytes32 salt, address account);
    /// @dev `predictCrossAccount` and `_deployAccount` disagree, so this chain's derivation
    ///      is not the one its deployer uses. Both are `virtual` and a spoke on a diverging
    ///      chain must override BOTH; this is what catches overriding one.
    error AccountAddressMismatch(address predicted, address deployed);
    error NoAccountImplementation();
    /// @dev Reachable only from a payload this contract is already executing, which means one
    ///      that arrived through an authenticated delivery.
    error NotSelfCall(address caller);

    /* ================================== routing ================================ */

    /// @dev PATH B'S OWN RECORD, because a transceiver is not an ERC-7786 gateway source and
    ///      so emits no `MessageSent`. It names the pair rather than hashing it:
    ///      `(chainKey, owner, salt)` is what an account IS, and it is what the registry slot
    ///      on the return leg is keyed by.
    event BootstrapSent(bytes32 indexed destinationChainKey, address indexed owner, bytes32 salt);

    /* ============================ account manufacture ========================== */

    /// @notice The salt an owner's account deploys at, on every chain.
    ///
    /// @dev THE OWNER AND A SALT THEY CHOOSE. The owner is what makes the address mean the
    ///      same thing on both sides: a CREATE2 address cannot be derived from itself, so the
    ///      account's own address could never serve, and the owner is the one identity the
    ///      home chain and the destination both name. The salt is what lets one owner hold
    ///      more than one account: one per purpose, per counterparty, per mandate.
    ///
    /// @dev IT IS HASHED, NOT CONCATENATED. `abi.encode` is fixed-width, so no `(owner, salt)`
    ///      pair can collide with another by sliding bytes across the boundary.
    function accountSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice Where an owner's account lives on this chain, before it exists.
    ///
    /// @dev THE DEFAULT IS ETHEREUM'S CREATE2, which is identical on every chain that shares
    ///      it because all three inputs are: this contract's address (hub and spoke share
    ///      one), the `(owner, salt)` pair, and a constant initcode.
    ///
    /// @dev `virtual` BECAUSE THE FORMULA IS A PROPERTY OF THE CHAIN, NOT OF THIS PROTOCOL.
    ///      zkSync and Tron are `eip155` and derive addresses differently, so a spoke there
    ///      MUST override this and `_deployAccount` together. Overriding one alone is caught
    ///      rather than trusted: `_createCrossAccount` compares what it deployed against what
    ///      this returned. See that function for what a chain-specific spoke owes.
    function predictCrossAccount(address owner, bytes32 salt)
        public
        view
        virtual
        returns (address)
    {
        return Create2.computeAddress(
            accountSalt(owner, salt), CROSS_PROXY_INIT_CODE_HASH, address(this)
        );
    }

    /// @notice Deploy the proxy at `salt`, and return where it actually landed.
    ///
    /// @dev SEPARATE FROM THE PREDICTION BECAUSE A CHAIN CAN DIVERGE IN EITHER, AND ZKSYNC
    ///      DIVERGES IN BOTH. Its addresses use a different formula AND it cannot deploy raw
    ///      initcode at all: deployment goes through a system contract against a bytecode
    ///      hash published in advance, so `type(CrossProxy).creationCode` is not a deploy
    ///      input there and `new CrossProxy{salt: s}()` is what a spoke must emit instead.
    ///      Tron diverges only in the formula.
    function _deployAccount(bytes32 salt) internal virtual returns (address deployed) {
        return Create2.deploy(0, salt, type(CrossProxy).creationCode);
    }

    /// @notice Deploy an owner's account and arm it with the logic this side installs.
    ///
    /// @dev ONE FUNCTION, TWO OUTCOMES, AND THE ADDRESS DOES NOT KNOW THE DIFFERENCE. A hub
    ///      installs a transmitter, a spoke installs a receiver, and both deploy the same
    ///      argument-free proxy at the same salt from the same address. What diverges is
    ///      `_accountImplementation`, which the derivation never sees.
    ///
    /// @dev DEPLOY, ARM, AND LOCK IN ONE CALL. `CrossProxy` offers no way to install logic
    ///      without surrendering the upgrade key in the same call, so there is no reachable
    ///      state in which an account has real logic and a live key.
    ///
    /// @dev IT ASSERTS THAT THE DEPLOYMENT LANDED WHERE THE PREDICTION SAID, and that check
    ///      is what makes the two seams above safe to override independently. Every address
    ///      this protocol publishes comes from `predictCrossAccount`: the peer a transmitter
    ///      records, the `sourceTransmitter` a receiver authenticates, the slot the registry
    ///      keys. A spoke whose formula disagreed with its deployer would arm nothing and
    ///      hand every one of those a phantom address.
    ///
    ///      Without it the failure is still closed, but only by accident: arming the
    ///      predicted address calls a function returning nothing, so Solidity's `extcodesize`
    ///      check reverts with no reason data. `AccountAddressMismatch` names which half is
    ///      wrong, which is the difference between a diagnosable spoke and an inexplicable
    ///      one.
    function _createCrossAccount(address owner, bytes32 salt, Call[] memory calls)
        internal
        returns (address account)
    {
        if (owner == address(0)) revert ZeroOwner();

        address implementation = _accountImplementation();
        if (implementation == address(0)) revert NoAccountImplementation();

        account = predictCrossAccount(owner, salt);
        if (account.code.length != 0) revert CrossAccountExists(owner, salt, account);

        address deployed = _deployAccount(accountSalt(owner, salt));
        if (deployed != account) revert AccountAddressMismatch(account, deployed);

        ICrossProxy(account).upgradeInitializeAndLock(
            implementation, _accountInitializer(owner, salt, calls)
        );

        emit CrossAccountCreated(owner, account, salt);
    }

    /// @notice Stand an account up on a chain that has none, and carry its payload.
    ///
    /// @dev PERMISSIONLESS, AND THE ARGUMENT IS THE ADDRESS. `msg.sender` must be what
    ///      `predictCrossAccount(owner, salt)` resolves to, so the only account anyone can
    ///      bootstrap is the one that already answers to them, and nobody gains anything by
    ///      paying to create somebody else's. That check is also what lets the owner and salt
    ///      travel in the message without a caller claiming another account's identity.
    ///
    /// @dev THE ONLY CALLER OF `_requireRoutable`, and therefore the only place
    ///      `minCounterpartProvenance` is enforced: a bar on the first message to a chain
    ///      rather than on every send, since once an account exists there its own sends go
    ///      straight to it and never reach this contract again.
    function bootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external payable {
        if (predictCrossAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        // The provenance bar lives inside this check: an under-graded counterpart, or an
        // unconfigured route, reverts before anything crosses.
        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, calls),
            attributes,
            _bootstrapSendValue(destinationChainKey)
        );
    }

    /// @notice `bootstrap`, for a destination whose calls this chain cannot express.
    /// @dev THE SAME CHECKS, THE OTHER FORM. Which one a caller may use is decided by the
    ///      destination's chain type and enforced at the transmitter, which still holds the
    ///      ERC-7930 envelope. This contract sees only a chainKey, which is a hash and cannot
    ///      be asked what chain type it came from.
    function bootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external payable {
        if (predictCrossAccount(owner, salt) != msg.sender) {
            revert NotTheAccount(owner, salt, msg.sender);
        }

        _requireRoutable(destinationChainKey);

        emit BootstrapSent(destinationChainKey, owner, salt);
        _sendMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, elements),
            attributes,
            _bootstrapSendValue(destinationChainKey)
        );
    }

    /// @notice What `bootstrap` would cost, before anything is spent.
    ///
    /// @dev THE MESSAGE A CALLER IS LEAST ABLE TO GUESS THE PRICE OF, AND THE ONE THAT FAILS
    ///      MOST EXPENSIVELY: a bootstrap carries account creation as well as the payload,
    ///      and an underfunded one is not a retry, because the account still does not exist
    ///      on that chain.
    ///
    /// @dev IT APPLIES `_requireRoutable` SO THE BAR FAILS THE QUOTE WHEREVER IT FAILS THE
    ///      SEND, but NOT `bootstrap`'s caller check: a quote is taken by an interface or a
    ///      signer BEFORE that account exists, so the same check would make the function
    ///      uncallable in exactly the case it is for. There is nothing to protect on a `view`.
    function quoteBootstrap(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        Call[] calldata calls,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        _requireRoutable(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrap(owner, salt, calls),
            attributes
        ) + _bootstrapSurcharge(destinationChainKey);
    }

    /// @notice `quoteBootstrap`, for a destination whose calls this chain cannot express.
    function quoteBootstrapElements(
        bytes32 destinationChainKey,
        address owner,
        bytes32 salt,
        bytes[] calldata elements,
        bytes[] calldata attributes
    ) external view returns (uint256 nativeFee) {
        _requireRoutable(destinationChainKey);
        return _quoteMessage(
            _recipientOn(destinationChainKey),
            Envelope.encodeBootstrapElements(owner, salt, elements),
            attributes
        ) + _bootstrapSurcharge(destinationChainKey);
    }

    /// @notice What this transceiver charges on top of the message, per destination.
    ///
    /// @dev IT IS IN THE QUOTE OR THE QUOTE IS A LIE. R2.5 says a quote must revert wherever
    ///      its send would, and a quote that omitted the fee would do worse than that: it
    ///      would succeed, and the caller would fund the send exactly, and the bootstrap
    ///      would revert `InsufficientBootstrapFee` with the signers already committed.
    function _bootstrapSurcharge(bytes32) internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice How much of `msg.value` a bootstrap may spend on the message itself.
    ///
    /// @dev THE SEAM THE FEE HANGS ON. A spoke never bootstraps anyone, so the default is
    ///      the whole value; a hub takes its per-destination fee off the top first, and the
    ///      binding is told what is left rather than reading `msg.value` and overspending.
    function _bootstrapSendValue(bytes32) internal virtual returns (uint256) {
        return msg.value;
    }

    /// @notice The logic this side installs. Hub: a transmitter. Spoke: a receiver.
    function _accountImplementation() internal view virtual returns (address);

    /// @notice The initializer that logic is armed with, run by delegatecall inside the
    ///         upgrade so the account is never live and uninitialized.
    ///
    /// @dev THIS IS WHERE PROVIDER SETUP HAS TO HAPPEN, AND THERE IS NO SECOND CHANCE. The
    ///      proxy locks in the same call that arms it, and an account's own configuration (a
    ///      peer table, a delegate) is gated on its OWNER, which this contract is not. So a
    ///      transceiver has no authority over an account after creating it, and anything the
    ///      provider needs must be folded into this calldata. `virtual` all the way down for
    ///      exactly that reason.
    function _accountInitializer(address owner, bytes32 salt, Call[] memory calls)
        internal
        view
        virtual
        returns (bytes memory);

    /// @notice The base hook, and the only thing it does is CLOSE THE TRANSCEIVER.
    ///
    /// @dev THE LOCK IS PART OF ARMING, NOT A LATER PROMISE. A transceiver decides which
    ///      cross-chain payloads are authentic, so a live upgrade key on one is a standing
    ///      ability to forge any message the protocol will honour. Locking on a separate
    ///      admin transaction means every deployment has a window where that key exists, and
    ///      nothing but intent closes it: an operator who forgets, or who is waiting to be
    ///      sure, is running an authenticator somebody can replace. Doing it here converts
    ///      "we will lock it" into "it was never unlocked", and the deployment either
    ///      produced a sealed transceiver or reverted.
    ///
    /// @dev THE PROXY STILL GETS ONE UPGRADE, WHICH IS THE ONE THAT RUNS THIS. A transceiver
    ///      lives at an address every account's CREATE2 depends on, so the proxy is deployed
    ///      through a keyless factory to fix that address without fixing the implementation,
    ///      then pointed at the real logic by an `upgradeToAndCall` carrying this
    ///      initializer. That call is authorized against the stub it is leaving; by the time
    ///      it returns the flag is set and `_authorizeUpgrade` refuses everything after. It
    ///      is `CrossProxy`'s sequence one level up: upgrade, initialize, lock, in one call.
    ///
    /// @dev IT IS CALLED LAST, BY `__HubTransceiverBase_init` AND `__SpokeTransceiverBase_init`
    ///      rather than by the binding, so a binding cannot ship a transceiver that never
    ///      locked by leaving a line out. Both halves already have an init a concrete
    ///      contract must call to be usable at all, so the lock rides on something that is
    ///      not optional.
    ///
    /// @dev THE COST IS THAT A BUG HERE IS PERMANENT, and the fix is a redeploy at a new
    ///      address, which re-derives every account. That is the same trade `_setRoute`
    ///      makes and the same answer: what the protocol guarantees is worth what the
    ///      smallest set of things able to change it is worth.
    ///
    /// @dev IT ALSO NAMES THE TWO THINGS A TRANSCEIVER CANNOT BE GIVEN LATER. The treasury
    ///      and the gateways are role membership, and `Roles` sets no role admin, so this call
    ///      is the only opportunity either will ever have, since `grantRole` closes with the
    ///      initialization window. See `Roles.grantRole`.
    ///
    /// @dev A ZERO TREASURY IS ALLOWED HERE AND COSTS A REDEPLOY. Fees accumulate against a
    ///      `withdrawFees` that can never name a valid destination, which is recoverable only
    ///      by deploying again. It is not refused because a deployment that collects no fees
    ///      is legitimate, and because refusing it would put a second address in the way of
    ///      the simplest possible transceiver.
    function __TransceiverBase_init(Deployment memory deployment)
        internal
        onlyInitializing
    {
        if (deployment.treasury != address(0)) {
            grantRole(TREASURY_ROLE, deployment.treasury);
        }
        for (uint256 i; i < deployment.gateways.length; ++i) {
            if (deployment.gateways[i] != address(0)) {
                grantRole(GATEWAY_ROLE, deployment.gateways[i]);
            }
        }

        upgradesLocked = true;
        emit UpgradesLocked();
    }

    /* ============================== authorization ============================== */

    /// @notice THE CONFIGURING AUTHORITY IS THE OWNER, and the roles are not authorities at
    ///         all. See `Roles` for why `TREASURY` and `GATEWAY` are addresses a deployment
    ///         names rather than powers a holder exercises, why neither has a role admin, and
    ///         why the role ids are namespaced.
    ///
    /// @dev A ROLE IS WHAT LETS THE BASE ASK ABOUT AN ADDRESS THAT IS NOT THE CALLER.
    ///      `withdrawFees` requires the DESTINATION to hold `TREASURY_ROLE`, which no
    ///      caller-shaped check can express: without it the owner could name any address at
    ///      all, and a fee taken to fund spokes could leave to somewhere that funds none.
    ///      That is the whole reason a treasury is a role and not an address slot.
    ///
    /// @dev AND IT ANSWERS "WHO ELSE", which is the question a predicate could not.
    ///      `getRoleMembers(GATEWAY_ROLE)` enumerates the transports this contract trusts, so
    ///      a live transceiver carrying one nobody remembers naming is visible rather than
    ///      merely present.

    /// @notice WHERE THE TWO SIDES DIVERGE, and the only thing that does. Both halves of
    ///         addressing (`_routeTo` and `_counterpartOn`) are `OutboundBase`'s seams, and a
    ///         transceiver differs from an account only in what it fills them with: a hub
    ///         overrides `_counterpartOn` to read the registry at a provenance bar, a spoke
    ///         overrides both to answer from write-once home values and refuse every other
    ///         key. Nothing here needs restating; see `OutboundBase._recipientOn`.

    /* ============================== upgrade lock =============================== */

    /// @dev Gate for UUPS, AND IT ASKS NOBODY. THERE IS NO `lockUpgrades()` TO CALL:
    ///      `__TransceiverBase_init` sets the flag and both halves call it last, so on any
    ///      initialized transceiver this refuses unconditionally. There is no second branch
    ///      because there is no state to reach it from: an uninitialized transceiver has no
    ///      owner on either half, so a caller check could only ever have refused as well.
    ///      The one upgrade a proxy gets is authorized against the stub it is leaving, not
    ///      here.
    function _authorizeUpgrade(address) internal view override {
        revert UpgradesAreLocked();
    }

    /* ================================= inbound ================================= */

    /// @notice Who may approve a hash here: nothing but a payload this contract is already
    ///         executing, which means one that arrived through `receiveMessage` from an
    ///         authenticated origin.
    ///
    /// @dev THE NARROWEST ANSWER AVAILABLE, and narrower than a receiver's. An account admits
    ///      its own transmitter as well, because an account has exactly one and it is the
    ///      party the account exists for. A transceiver is shared by every owner on its chain
    ///      and has no equivalent, so anything wider would let one party approve work that
    ///      binds the contract everyone else's bootstrap goes through.
    function _checkCommitter() internal view override {
        if (msg.sender != address(this)) revert NotSelfCall(msg.sender);
    }

    /// @notice Which origins a delivery is accepted from: the counterpart on the chain the
    ///         message says it came from, at this transceiver's bar.
    /// @dev It splits the ERC-7930 sender envelope the way every binding already does — the
    ///      chain half is the route, the address half is the sender — and hands both to
    ///      `_authenticateOrigin`, so `receiveMessage` and a binding's own inbound callback
    ///      reach the same check rather than two that could drift.
    function _authenticateSender(bytes calldata sender) internal view override {
        _authenticateOrigin(
            Erc7930.toChainIdentifier(sender), Erc7930.parseStrict(sender).addr
        );
    }

    /// @notice What an arriving payload is allowed to call. NOT ARBITRARY, unlike an
    ///         account's.
    ///
    /// @dev A TRANSCEIVER EXECUTES ARRAYS AND MUST NOT EXECUTE ANY ARRAY. It is the contract
    ///      that authenticates every inbound message, holds the fee balance, and deploys every
    ///      account on its chain, so an unconstrained `_execute` here hands an authenticated
    ///      counterpart the transceiver's whole address. Two concrete escalations that closes,
    ///      both of which a shipped version would have had:
    ///
    ///      A SELF-CALL TO A SELF-GATED FUNCTION IS INDISTINGUISHABLE FROM THE REAL PATH.
    ///      `HubTransceiverBase.onDestinationReceiver` is `require(msg.sender == address(this))`
    ///      and takes its `chainKey` as an argument, which the envelope path fills from
    ///      `_authenticateOrigin`. An executed payload could call it directly with any chainKey
    ///      at all, so a spoke on one chain could pin an account's receiver on another —
    ///      exactly the invariant `ReportedChainMismatch` exists to hold, reached around the
    ///      side. The slot is write-once, so it would not have been recoverable.
    ///
    ///      A `Call` CARRIES VALUE. An executed payload could send the balance anywhere,
    ///      bypassing `withdrawFees`, its owner gate, the `TREASURY_ROLE` destination check,
    ///      and the `collectedFees` accounting in one call.
    ///
    /// @dev SO THE ANSWER IS AN ALLOWLIST, AND IT IS TWO ENTRIES LONG. A payload may approve a
    ///      hash on this contract, and — on a spoke, which extends this — discharge one into a
    ///      bootstrap. Both targets are `address(this)` and both functions are non-payable, so
    ///      a call carrying value reverts without this having to reason about value at all.
    ///      Anything else a transceiver needs to be told arrives as an envelope through
    ///      `_onInbound`, where the argument comes from the authenticated origin rather than
    ///      from the payload.
    function isAllowed(address target, bytes4 selector)
        public
        view
        virtual
        override
        returns (bool)
    {
        return target == address(this)
            && (
                selector == ICommitFinalize.commit.selector
                    || selector == ICancel.cancel.selector
            );
    }

    /// @notice Withdraw an approval this transceiver is holding.
    ///
    /// @dev GATED LIKE `commit`, WHICH MEANS A PAYLOAD AND NOT A CALLER. The only way to reach
    ///      it is an array this contract is already executing, which arrived from the
    ///      authenticated counterpart or discharged an approval that did. So the authority
    ///      that approved a bootstrap is the authority that can withdraw it, and no caller
    ///      gains anything: an openly reachable cancel on a contract every owner's bootstrap
    ///      goes through would let whoever found it strip a bootstrap somebody else paid for.
    ///
    /// @dev WITHOUT IT AN APPROVED BOOTSTRAP COULD NEVER BE WITHDRAWN. It would sit
    ///      indefinitely, and because `finalize` is permissionless and has no deadline, the
    ///      moment it executed — and so the state its payload ran against — would belong to
    ///      whoever chose to supply the array.
    function cancel(bytes32 commitment_) external virtual override {
        _checkCommitter();
        _cancel(commitment_);
    }

    /// @notice The one funnel every protocol binding routes an arriving message into.
    ///
    /// @dev AUTHENTICATION IS NOT THE BINDING'S JOB. It runs here, before anything is
    ///      decoded, so a new binding cannot ship without it: the binding's only inbound
    ///      responsibility is translating its SDK's callback into these three arguments.
    ///
    /// @dev IT SPLITS INTO TWO VIRTUALS BECAUSE TWO THINGS VARY INDEPENDENTLY. Who may send
    ///      varies by CARDINALITY: a spoke compares against constants, a hub resolves N
    ///      origins through the registry. What they may say varies by DIRECTION: a spoke
    ///      receives bootstraps, a hub receives reports. One overridable hook would let a
    ///      subclass get the second right and the first wrong.
    ///
    /// @param route   How the source chain is named, as the provider reported it.
    /// @param sender  The counterpart's address on that chain, in that chain's own format.
    /// @param message The body: see `Envelope`.
    function _onInbound(bytes memory route, bytes memory sender, bytes calldata message)
        internal
    {
        bytes32 chainKey = _authenticateOrigin(route, sender);
        _handleInbound(chainKey, message);
    }

    /// @notice Establish which chain this came from, and refuse it if the sender is not that
    ///         chain's counterpart.
    /// @dev Hub: reverse-index the route, then compare against the registry's counterpart at
    ///      the provenance bar. Spoke: compare against two write-once values.
    function _authenticateOrigin(bytes memory route, bytes memory sender)
        internal
        view
        virtual
        returns (bytes32 chainKey);

    /// @notice Act on an authenticated message.
    /// @dev Hub: a receiver report. Spoke: a bootstrap. Each side decodes exactly one shape,
    ///      which is why `Envelope` carries no type tag.
    function _handleInbound(bytes32 chainKey, bytes calldata message) internal virtual;
}
