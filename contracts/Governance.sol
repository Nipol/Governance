/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "@beandao/contracts/library/EIP712.sol";
import "@beandao/contracts/library/Scheduler.sol";
import "@beandao/contracts/library/Wizadry.sol";
import "@beandao/contracts/interfaces/IERC165.sol";
import "@beandao/contracts/interfaces/IERC721.sol";
//1155 received
import "./IGovernance.sol";
import "./ICouncil.sol";

import "hardhat/console.sol";

/**
 * @title Governance
 * @author yoonsung.eth
 * @notice DAO의 지갑이자, 거버넌스 역할을 수행할 최종 인스턴스.
 * - 거버넌스는 카운슬의 실행 가능성에만 보팅에 대해 검증만 수행하기 때문에 거버넌스는 카운슬 구성원을 알수도 없고, 의존 및 관심사를 분리함
 */
contract Governance is IGovernance, Wizadry, Scheduler, Initializer {
    uint32 constant GRACE_PERIOD = 7 days;
    uint32 constant MINIMUM_DELAY = 1 days;
    uint32 constant MAXIMUM_DELAY = 30 days;
    string public constant version = "1";

    /**
     * @notice 어떤 거버넌스인지에 대해 사람이 읽을 수 있는 형태의 이름
     */
    string public name;

    /**
     * @notice 거버넌스 보팅을 계산할 이사회 컨트랙트, EOA도 가능하다.
     */
    address public council;

    /**
     * @notice 고유한 Proposal 아이디 생성을 위한 내부 순서
     */
    uint128 public nonce;

    /**
     * @notice keccak256(contract address ++ contract versrion ++ proposer address ++ nonce) to proposal
     */
    mapping(bytes32 => Proposal) public proposals;

    /**
     * @notice 자기 자신 Governance 컨트랙트만 호출이 가능함.
     */
    modifier onlyGov() {
        require(msg.sender == address(this), "Governance/Only-Governance");
        _;
    }

    /**
     * @notice 해당 호출은 이사회 컨트랙트만 가능함.
     */
    modifier onlyCouncil() {
        require(msg.sender == council, "Governance/Only-Council");
        _;
    }

    /**
     * @notice 해당 함수는 컨트랙트가 배포될 때 단 한번만 호출 되며, 다시는 호출할 수 없습니다. 거버넌스의 이름, 초기 Council, 실행 딜레이를
     * @dev 보팅 기간, 실행 대기 기간,
     * @param govName 해당 거버넌스의 이름, 사람이 읽을 수 있는 형태
     * @param initialCouncil 거버넌스를 통제할 Council 컨트랙트 주소, EOA일 수도 있으나 0x0이 될 수는 없다.
     * @param executeDelay 거버넌스로 사용될 기본 딜레이, Scheduler의 기준을 따르며, 1일 이상이여야 한다.
     */
    function initialize(
        string memory govName,
        address initialCouncil,
        uint32 executeDelay
    ) external initializer {
        require(initialCouncil != address(0));
        name = govName;
        council = initialCouncil;
        setDelay(executeDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
    }

    /**
     * @notice 거버넌스를 통해 실행될 제안을 등록합니다.
     * @param params ProposalParams 구조체의 값
     * @return proposalId 해당 제안의 고유값
     * @return id 해당 제안의 순서 값
     */
    function propose(ProposalParams memory params) external onlyCouncil returns (bytes32 proposalId, uint128 id) {
        id = ++nonce;
        proposalId = keccak256(abi.encode(address(this), version, msg.sender, id));
        Proposal storage p = proposals[proposalId];
        (p.id, p.proposer, p.spells, p.elements) = (id, params.proposer, params.spells, params.elements);
        emit Proposed(proposalId, id, params.spells, msg.sender, params.proposer);
    }

    /**
     * @notice 등록된 제안을 실행 대기열에 등록하며, Council에서 Proposal이 승인 되었을 때 실행
     * @param proposalId Proposal에 대한 고유 아이디
     * @return success 해당 실행이 성공적인지 여부
     */
    function ready(bytes32 proposalId) external onlyCouncil returns (bool success) {
        require(proposals[proposalId].id > 0, "Governance/Not-Proposed");
        queue(proposalId);
        success = true;
        emit Ready(proposalId);
    }

    /**
     * @notice 등록한 제안을 대기열에서 삭제시키며, Council에서 Proposal이 승인되지 않았을 때 실행
     * @param proposalId Proposal에 대한 고유 아이디
     * @return success 해당 실행이 성공적인지 여부
     */
    function drop(bytes32 proposalId) external onlyCouncil returns (bool success) {
        Proposal storage p = proposals[proposalId];
        require(p.id > 0, "Governance/Not-Proposed");
        p.canceled = true;
        delete p.elements;
        delete p.spells;
        success = true;
        emit Dropped(proposalId);
    }

    /**
     * @notice 대기열에 등록되어 대기 시간이 경과된 제안서에 포함된 로직을 실행하며, 예비 기간이 지난 이후 실행되면 해당 제안서가 취소됨
     * @param proposalId Proposal에 대한 고유 아이디
     */
    function execute(bytes32 proposalId) external onlyCouncil {
        resolve(proposalId, GRACE_PERIOD);
        Proposal memory p = proposals[proposalId];
        if (stateOf[proposalId] == STATE.RESOLVED) {
            cast(p.spells, p.elements);
            proposals[proposalId].executed = true;
        } else {
            proposals[proposalId].canceled = true;
        }
        emit Executed(proposalId);
    }

    /**
     * @notice 연결된 카운슬을 다른 카운슬 컨트랙트로 변경한다. 이때 일반적인 EOA로는 이관할 수 없다.
     */
    function changeCouncil(address councilAddr) external onlyGov {
        require(IERC165(councilAddr).supportsInterface(type(ICouncil).interfaceId), "Governance/Only-Council-Contract");
        council = councilAddr;
    }

    /**
     * @notice Governance의 실행 지연 시간을 변경합니다.
     */
    function changeDelay(uint32 executeDelay) external onlyGov {
        setDelay(executeDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
    }

    /**
     * @notice Council의 임계에 따라서, 긴급하게 허용해야하는 실행데이터
     * @param spells 실행 커맨드 값
     * @param elements 커맨드가 사용할 엘리먼츠 값
     */
    function emergencyExecute(bytes32[] calldata spells, bytes[] memory elements) external onlyCouncil {
        ++nonce;
        cast(spells, elements);
    }

    /**
     * @notice 현재 연결되어 있는 카운슬을 다른 주소로 변경하며, 이때 어떤 주소로든 이관할 수 있다.
     */
    function emergencyCouncil(address councilorAddr) external onlyGov {
        require(council != councilorAddr && councilorAddr != address(this), "Governance/Invalid-Address");
        council = councilorAddr;
    }

    /**
     * @notice Council이 EOA로 등록된 경우, EOA가 Governance를 대신하여 Off-chain 투표를 수행하도록 합니다.
     */
    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4 magicValue) {
        require(signature.length == 65, "invalid signature length");
        uint8 v;
        bytes32 r;
        bytes32 s;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            v := and(mload(add(signature, 65)), 255)
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
        }

        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert("invalid signature 's' value");
        }

        if (v != 27 && v != 28) {
            revert("invalid signature 'v' value");
        }

        address signer = ecrecover(digest, v, r, s);

        assert(signer != address(0));
        if (council == signer) {
            // bytes4(keccak256("isValidSignature(bytes32,bytes)"))
            magicValue = 0x1626ba7e;
        } else {
            magicValue = 0xffffffff;
        }
    }

    /// @notice Handle the receipt of an NFT
    /// @dev The ERC721 smart contract calls this function on the recipient
    ///  after a `transfer`. This function MAY throw to revert and reject the
    ///  transfer. Return of other than the magic value MUST result in the
    ///  transaction being reverted.
    ///  Note: the contract address is always the message sender.
    /// @param _operator The address which called `safeTransferFrom` function
    /// @param _from The address which previously owned the token
    /// @param _tokenId The NFT identifier which is being transferred
    /// @param _data Additional data with no specified format
    /// @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    ///  unless throwing
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes memory _data
    ) external returns (bytes4) {
        IERC721(msg.sender).setApprovalForAll(_operator, false);
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }
}
