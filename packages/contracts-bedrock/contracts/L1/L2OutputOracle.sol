// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Semver} from "../universal/Semver.sol";
import {Types} from "../libraries/Types.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OptimisticOracleV3Interface} from "../periphery/OptimisticOracleV3Interface.sol";
import "../periphery/AncillaryData.sol";

interface Module {
    function getSequencer() external returns (address);

    function slash(address) external returns (bool);

    function reward(address) external returns (bool);

    function lock(address) external returns (bool);

    function unlock(address) external returns (bool);
}

/**
 * @custom:proxied
 * @title L2OutputOracle
 * @notice The L2OutputOracle contains an array of L2 state outputs, where each output is a
 *         commitment to the state of the L2 chain. Other contracts like the OptimismPortal use
 *         these outputs to verify information about the state of L2.
 */
contract L2OutputOracle is Initializable, Semver {
    using SafeERC20 for IERC20;
    /**
     * @notice The interval in L2 blocks at which checkpoints must be submitted. Although this is
     *         immutable, it can safely be modified by upgrading the implementation contract.
     */

    uint256 public immutable SUBMISSION_INTERVAL;

    /**
     * @notice The time between L2 blocks in seconds. Once set, this value MUST NOT be modified.
     */
    uint256 public immutable L2_BLOCK_TIME;

    /**
     * @notice The address of the challenger. Can be updated via upgrade.
     */
    address public immutable CHALLENGER;

    /**
     * @notice The address of the proposer. Can be updated via upgrade.
     */
    address public PROPOSER;

    /**
     * @notice Minimum time (in seconds) that must elapse before a withdrawal can be finalized and UMA liveness
     */
    uint64 public immutable FINALIZATION_PERIOD_SECONDS;

    /**
     * @notice The number of the first L2 block recorded in this contract.
     */
    uint256 public startingBlockNumber;

    /**
     * @notice The timestamp of the first L2 block recorded in this contract.
     */
    uint256 public startingTimestamp;

    /**
     * @notice Array of L2 output proposals.
     */
    Types.OutputProposal[] internal l2Outputs;

    /**
     * @notice UMA: default currency for bonds.
     */
    IERC20 public DEFAULT_CURRENCY;

    /**
     * @notice UMA: Optimistic Oracle (OO).
     */
    OptimisticOracleV3Interface public OO;

    /**
     * @notice UMA: OO identifier.
     */
    bytes32 public DEFAULT_IDENTIFIER;

    /**
     * @notice UMA: Data assertion structure.
     */
    struct DataAssertion {
        bytes32 dataId; // The dataId that was asserted.
        bytes32 data; // This could be an arbitrary data type.
        address asserter; // The address that made the assertion.
        bool resolved; // Whether the assertion has been resolved.
        uint256 l2OutputIndex; // Index of the output in the l2Outputs array.
    }

    /**
     * @notice UMA: Assertion data.
     */
    mapping(bytes32 => DataAssertion) public assertionsData;

    /**
     * @notice Restaking: Module address.
     */
    address public RESTAKING_MODULE;

    /**
     * @notice Emitted when an output is proposed.
     *
     * @param outputRoot    The output root.
     * @param l2OutputIndex The index of the output in the l2Outputs array.
     * @param l2BlockNumber The L2 block number of the output root.
     * @param l1Timestamp   The L1 timestamp when proposed.
     */
    event OutputProposed(
        bytes32 indexed outputRoot, uint256 indexed l2OutputIndex, uint256 indexed l2BlockNumber, uint256 l1Timestamp
    );

    /**
     * @notice Emitted when outputs are deleted.
     *
     * @param prevNextOutputIndex Next L2 output index before the deletion.
     * @param newNextOutputIndex  Next L2 output index after the deletion.
     */
    event OutputsDeleted(uint256 indexed prevNextOutputIndex, uint256 indexed newNextOutputIndex);

    /**
     * @custom:semver 1.2.0
     *
     * @param _submissionInterval  Interval in blocks at which checkpoints must be submitted.
     * @param _l2BlockTime         The time per L2 block, in seconds.
     * @param _startingBlockNumber The number of the first L2 block.
     * @param _startingTimestamp   The timestamp of the first L2 block.
     * @param _proposer            The address of the proposer.
     * @param _challenger          The address of the challenger.
     */
    constructor(
        uint256 _submissionInterval,
        uint256 _l2BlockTime,
        uint256 _startingBlockNumber,
        uint256 _startingTimestamp,
        address _proposer,
        address _challenger,
        uint64 _finalizationPeriodSeconds
    ) Semver(1, 2, 0) {
        require(_l2BlockTime > 0, "L2OutputOracle: L2 block time must be greater than 0");
        require(
            _submissionInterval > _l2BlockTime, "L2OutputOracle: submission interval must be greater than L2 block time"
        );

        SUBMISSION_INTERVAL = _submissionInterval;
        L2_BLOCK_TIME = _l2BlockTime;
        PROPOSER = _proposer;
        CHALLENGER = _challenger;
        FINALIZATION_PERIOD_SECONDS = _finalizationPeriodSeconds;

        // note: using UMA addresses for Goerli
        setupRestaking(0x07865c6E87B9F70255377e024ace6630C1Eaa37F, 0x9923D42eF695B5dd9911D05Ac944d4cAca3c4EAB, CHALLENGER);

        initialize(_startingBlockNumber, _startingTimestamp);
    }

    function setupRestaking(address _defaultCurrency, address _optimisticOracleV3, address _restakingModule) public {
        DEFAULT_CURRENCY = IERC20(_defaultCurrency);
        OO = OptimisticOracleV3Interface(_optimisticOracleV3);
        DEFAULT_IDENTIFIER = OO.defaultIdentifier();

        RESTAKING_MODULE = _restakingModule;
    }

    /**
     * @notice Initializer.
     *
     * @param _startingBlockNumber Block number for the first recoded L2 block.
     * @param _startingTimestamp   Timestamp for the first recoded L2 block.
     */
    function initialize(uint256 _startingBlockNumber, uint256 _startingTimestamp) public initializer {
        require(
            _startingTimestamp <= block.timestamp,
            "L2OutputOracle: starting L2 timestamp must be less than current time"
        );

        startingTimestamp = _startingTimestamp;
        startingBlockNumber = _startingBlockNumber;
    }

    /**
     * @notice Deletes all output proposals after and including the proposal that corresponds to
     *         the given output index. Only the challenger address can delete outputs.
     *
     * @param _l2OutputIndex Index of the first L2 output to be deleted. All outputs after this
     *                       output will also be deleted.
     */
    // solhint-disable-next-line ordering
    function deleteL2Outputs(uint256 _l2OutputIndex) external {
        require(msg.sender == CHALLENGER, "L2OutputOracle: only the challenger address can delete outputs");

        _deleteL2Outputs(_l2OutputIndex);
    }

    function _deleteL2Outputs(uint256 _l2OutputIndex) internal {
        // Make sure we're not *increasing* the length of the array.
        require(
            _l2OutputIndex < l2Outputs.length, "L2OutputOracle: cannot delete outputs after the latest output index"
        );

        // Do not allow deleting any outputs that have already been finalized.
        require(
            block.timestamp - l2Outputs[_l2OutputIndex].timestamp < FINALIZATION_PERIOD_SECONDS,
            "L2OutputOracle: cannot delete outputs that have already been finalized"
        );

        uint256 prevNextL2OutputIndex = nextOutputIndex();

        // Use assembly to delete the array elements because Solidity doesn't allow it.
        assembly {
            sstore(l2Outputs.slot, _l2OutputIndex)
        }

        emit OutputsDeleted(prevNextL2OutputIndex, _l2OutputIndex);
    }

    /**
     * @notice Accepts an outputRoot and the timestamp of the corresponding L2 block. The timestamp
     *         must be equal to the current value returned by `nextTimestamp()` in order to be
     *         accepted. This function may only be called by the Proposer.
     *
     * @param _outputRoot    The L2 output of the checkpoint block.
     * @param _l2BlockNumber The L2 block number that resulted in _outputRoot.
     * @param _l1BlockHash   A block hash which must be included in the current chain.
     * @param _l1BlockNumber The block number with the specified block hash.
     */
    function proposeL2Output(bytes32 _outputRoot, uint256 _l2BlockNumber, bytes32 _l1BlockHash, uint256 _l1BlockNumber)
        external
        payable
    {
        uint256 bond = OO.getMinimumBond(address(DEFAULT_CURRENCY));
        DEFAULT_CURRENCY.safeTransferFrom(msg.sender, address(this), bond);
        DEFAULT_CURRENCY.safeApprove(address(OO), bond);
        // The claim we want to assert is the first argument of assertTruth. It must contain all of the relevant
        // details so that anyone may verify the claim without having to read any further information on chain. As a
        // result, the claim must include both the data id and data, as well as a set of instructions that allow anyone
        // to verify the information in publicly available sources.
        // See the UMIP corresponding to the defaultIdentifier used in the OptimisticOracleV3 "ASSERT_TRUTH" for more
        // information on how to construct the claim.
        // TODO: data object that combines the output root, the l2 block number, l1 block hash, and l1 block number
        bytes32 assertionId = OO.assertTruth(
            abi.encodePacked(
                "Data asserted: 0x", // _outputRoot is type bytes32 so we add the hex prefix 0x.
                AncillaryData.toUtf8Bytes(_outputRoot),
                " for dataId: 0x",
                AncillaryData.toUtf8BytesAddress(address(this)),
                " and asserter: 0x",
                AncillaryData.toUtf8BytesAddress(msg.sender),
                " at timestamp: ",
                AncillaryData.toUtf8BytesUint(block.timestamp),
                " in the DataAsserter contract at 0x",
                AncillaryData.toUtf8BytesAddress(address(this)),
                " is valid."
            ),
            msg.sender,
            address(this),
            address(0), // No sovereign security.
            FINALIZATION_PERIOD_SECONDS,
            DEFAULT_CURRENCY,
            bond,
            DEFAULT_IDENTIFIER,
            bytes32(0) // No domain.
        );
        assertionsData[assertionId] = DataAssertion(_outputRoot, _outputRoot, msg.sender, false, l2Outputs.length);

        require(
            _l2BlockNumber == nextBlockNumber(),
            "L2OutputOracle: block number must be equal to next expected block number"
        );

        require(
            computeL2Timestamp(_l2BlockNumber) < block.timestamp,
            "L2OutputOracle: cannot propose L2 output in the future"
        );

        require(_outputRoot != bytes32(0), "L2OutputOracle: L2 output proposal cannot be the zero hash");

        if (_l1BlockHash != bytes32(0)) {
            // This check allows the proposer to propose an output based on a given L1 block,
            // without fear that it will be reorged out.
            // It will also revert if the blockheight provided is more than 256 blocks behind the
            // chain tip (as the hash will return as zero). This does open the door to a griefing
            // attack in which the proposer's submission is censored until the block is no longer
            // retrievable, if the proposer is experiencing this attack it can simply leave out the
            // blockhash value, and delay submission until it is confident that the L1 block is
            // finalized.
            require(
                blockhash(_l1BlockNumber) == _l1BlockHash,
                "L2OutputOracle: block hash does not match the hash at the expected height"
            );
        }

        emit OutputProposed(_outputRoot, nextOutputIndex(), _l2BlockNumber, block.timestamp);

        l2Outputs.push(
            Types.OutputProposal({
                outputRoot: _outputRoot,
                timestamp: uint128(block.timestamp),
                l2BlockNumber: uint128(_l2BlockNumber)
            })
        );
    }

    /**
     * @notice Callback to receive the resolution result of an assertion.
     *
     * @param assertionId Assertion ID.
     *
     * @param assertedTruthfully Resolution result.
     */
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(OO));

        DataAssertion memory dataAssertion = assertionsData[assertionId];

        // If the assertion was true, reward the proposer
        // If the assertion was false, then delete the L2 outputs from that index forward.
        if (assertedTruthfully) {
            assertionsData[assertionId].resolved = true;
            Module(RESTAKING_MODULE).reward(dataAssertion.asserter);
        } else {
            // first we need to make absolutely sure to remove the corrupt l2 outputs
            _deleteL2Outputs(dataAssertion.l2OutputIndex);
            Module(RESTAKING_MODULE).slash(dataAssertion.asserter);

            // Delete the data assertion if it was false to save gas.
            delete assertionsData[assertionId];
        }

        // Unlock the stake of the sequencer in the restaking module
        Module(RESTAKING_MODULE).unlock(dataAssertion.asserter);
    }
    /**
     * @notice If assertion is disputed, lock the stake of the sequencer in the restaking module
     */

    function assertionDisputedCallback(bytes32 assertionId) public {
        require(msg.sender == address(OO));

        DataAssertion memory dataAssertion = assertionsData[assertionId];

        // Lock the stake of the sequencer in the restaking module
        Module(RESTAKING_MODULE).lock(dataAssertion.asserter);
    }

    /**
     * @notice Returns an output by index. Exists because Solidity's array access will return a
     *         tuple instead of a struct.
     *
     * @param _l2OutputIndex Index of the output to return.
     *
     * @return The output at the given index.
     */
    function getL2Output(uint256 _l2OutputIndex) external view returns (Types.OutputProposal memory) {
        return l2Outputs[_l2OutputIndex];
    }

    /**
     * @notice Returns the index of the L2 output that checkpoints a given L2 block number. Uses a
     *         binary search to find the first output greater than or equal to the given block.
     *
     * @param _l2BlockNumber L2 block number to find a checkpoint for.
     *
     * @return Index of the first checkpoint that commits to the given L2 block number.
     */
    function getL2OutputIndexAfter(uint256 _l2BlockNumber) public view returns (uint256) {
        // Make sure an output for this block number has actually been proposed.
        require(
            _l2BlockNumber <= latestBlockNumber(),
            "L2OutputOracle: cannot get output for a block that has not been proposed"
        );

        // Make sure there's at least one output proposed.
        require(l2Outputs.length > 0, "L2OutputOracle: cannot get output as no outputs have been proposed yet");

        // Find the output via binary search, guaranteed to exist.
        uint256 lo = 0;
        uint256 hi = l2Outputs.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (l2Outputs[mid].l2BlockNumber < _l2BlockNumber) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        return lo;
    }

    /**
     * @notice Returns the L2 output proposal that checkpoints a given L2 block number. Uses a
     *         binary search to find the first output greater than or equal to the given block.
     *
     * @param _l2BlockNumber L2 block number to find a checkpoint for.
     *
     * @return First checkpoint that commits to the given L2 block number.
     */
    function getL2OutputAfter(uint256 _l2BlockNumber) external view returns (Types.OutputProposal memory) {
        return l2Outputs[getL2OutputIndexAfter(_l2BlockNumber)];
    }

    /**
     * @notice Returns the number of outputs that have been proposed. Will revert if no outputs
     *         have been proposed yet.
     *
     * @return The number of outputs that have been proposed.
     */
    function latestOutputIndex() external view returns (uint256) {
        return l2Outputs.length - 1;
    }

    /**
     * @notice Returns the index of the next output to be proposed.
     *
     * @return The index of the next output to be proposed.
     */
    function nextOutputIndex() public view returns (uint256) {
        return l2Outputs.length;
    }

    /**
     * @notice Returns the block number of the latest submitted L2 output proposal. If no proposals
     *         been submitted yet then this function will return the starting block number.
     *
     * @return Latest submitted L2 block number.
     */
    function latestBlockNumber() public view returns (uint256) {
        return l2Outputs.length == 0 ? startingBlockNumber : l2Outputs[l2Outputs.length - 1].l2BlockNumber;
    }

    /**
     * @notice Computes the block number of the next L2 block that needs to be checkpointed.
     *
     * @return Next L2 block number.
     */
    function nextBlockNumber() public view returns (uint256) {
        return latestBlockNumber() + SUBMISSION_INTERVAL;
    }

    /**
     * @notice Returns the L2 timestamp corresponding to a given L2 block number.
     *
     * @param _l2BlockNumber The L2 block number of the target block.
     *
     * @return L2 timestamp of the given block.
     */
    function computeL2Timestamp(uint256 _l2BlockNumber) public view returns (uint256) {
        return startingTimestamp + ((_l2BlockNumber - startingBlockNumber) * L2_BLOCK_TIME);
    }

    function letsGetDaProposer() external view returns (address) {
        return PROPOSER;
    }

    function changeTheProposer(address _proposer) external returns (address) {
        PROPOSER = _proposer;
        return PROPOSER;
    }
}
