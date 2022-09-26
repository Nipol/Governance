/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "@beandao/contracts/library/Initializer.sol";
import "@beandao/contracts/library/EIP712.sol";
import "@beandao/contracts/library/Scheduler.sol";
import "./Wizadry.sol";
import "./IGovernance.sol";
import "./ICouncil.sol";

error Governance__FromNotCouncil(address caller);

error Governance__FromNotGovernance(address caller);

error Governance__InvalidExecuteData(bytes16 invalid);

error Governance__InvalidAddress(address invalid);

error Governance__NotProposed(bytes32 proposalId);

error Governance__NotCouncilContract(address contractAddr);

error Governance__NoneERC165Interface(address CouncilAddr);

error Governance__InvalidSignature();

error Governance__InvalidSignature_S();

error Governance__InvalidSignature_V();

/**
 * @title Governance
 * @author yoonsung.eth
 * @notice DAO의 지갑이자, 거버넌스 역할을 수행할 최종 인스턴스.
 * - 거버넌스는 카운슬의 실행 가능성에만 보팅에 대해 검증만 수행하기 때문에 거버넌스는 카운슬 구성원을 알수도 없음.
 */
contract Governance is Wizadry, Scheduler, IGovernance {
    string public constant version = "1";
    uint32 public constant GRACE_PERIOD = 7 days;
    uint32 public constant MINIMUM_DELAY = 1 days;
    uint32 public constant MAXIMUM_DELAY = 30 days;

    /**
     * @notice 거버넌스 보팅을 계산할 이사회 컨트랙트, EOA도 가능하다.
     */
    address public council;

    /**
     * @notice 고유한 Proposal 아이디 생성을 위한 내부 순서
     */
    uint96 public nonce;

    /**
     * @notice keccak256(contract address ++ contract versrion ++ proposer address ++ nonce) to proposal
     */
    mapping(bytes32 => Proposal) public proposals;

    /**
     * @notice 자기 자신 Governance 컨트랙트만 호출이 가능함.
     */
    modifier onlyGov() {
        if (msg.sender != address(this)) {
            revert Governance__FromNotGovernance(msg.sender);
        }
        _;
    }

    /**
     * @notice 해당 호출은 이사회 컨트랙트만 가능함.
     */
    modifier onlyCouncil() {
        if (msg.sender != council) {
            revert Governance__FromNotCouncil(msg.sender);
        }
        _;
    }

    /**
     * @notice  해당 함수는 컨트랙트가 배포될 때 단 한번만 호출 되며, 다시는 호출할 수 없습니다. 거버넌스의 초기 Council, 실행 딜레이를
     * @param   executeDelay 거버넌스로 사용될 기본 딜레이, Scheduler의 기준을 따르며, 1일 이상이여야 한다.
     */
    constructor(uint32 executeDelay) {
        council = msg.sender;
        setDelay(executeDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
    }

    /**
     * @notice  사람이 읽을 수 있는 거버넌스 이름
     */
    function name() public pure returns (string memory) {
        // bean the DAO
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x20, 0x20)
            mstore(0x4c, 0x0c6265616e207468652044414f)
            return(0x20, 0x60)
        }
    }

    /**
     * @notice  카운슬을 통해 거버넌스가 실행할 제안을 등록합니다.
     * @dev     this + version + nonce + council + proposer + spells + elements
     * @param   params 제안 정보를 담고 있는 구조체
     * @return  proposalId 해당 제안의 고유 아이디
     */
    function propose(ProposalParams calldata params) external onlyCouncil returns (bytes32 proposalId) {
        unchecked {
            proposalId = keccak256(
                abi.encodePacked(
                    address(this),
                    version,
                    nonce++,
                    council,
                    params.proposer,
                    params.spells,
                    abi.encode(params.elements)
                )
            );
        }
        Proposal storage p = proposals[proposalId];
        (p.spells, p.elements, p.state) = (params.spells, params.elements, ProposalState.AWAIT);

        emit Proposed(proposalId, version, nonce, msg.sender, params.proposer);
    }

    /**
     * @notice  등록된 제안을 실행 대기열에 등록하며, Council에서 Proposal이 승인 되었을 때 실행
     * @dev     카운슬만 호출 가능 함
     * @param   proposalId Proposal에 대한 고유 아이디
     */
    function approve(bytes32 proposalId) external onlyCouncil returns (bool success) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.AWAIT) {
            revert Governance__NotProposed(proposalId);
        }
        p.state = ProposalState.APPROVED;
        queue(proposalId);
        success = true;
        emit Approved(proposalId);
    }

    /**
     * @notice  등록한 제안을 대기열에서 삭제시키며, Council에서 Proposal이 승인되지 않았을 때 실행
     * @dev     카운슬만 호출 가능 함
     * @param   proposalId Proposal에 대한 고유 아이디
     */
    function drop(bytes32 proposalId) external onlyCouncil returns (bool success) {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.AWAIT) {
            revert Governance__NotProposed(proposalId);
        }
        p.state = ProposalState.DROPPED;
        delete p.spells;
        delete p.elements;
        success = true;
        emit Dropped(proposalId);
    }

    /**
     * @notice  대기열에 등록되어 대기 시간이 경과된 제안서에 포함된 로직을 실행하며, 예비 기간이 지난 이후 실행되면 해당 제안서가 취소됨
     * @dev     카운슬만 호출 가능 함
     * @param   proposalId Proposal에 대한 고유 아이디
     */
    function execute(bytes32 proposalId) external onlyCouncil {
        // 큐에 등록되었는지, 그리고 실행 가능한 기간
        resolve(proposalId, GRACE_PERIOD);
        Proposal storage p = proposals[proposalId];

        if (taskOf[proposalId].state == STATE.RESOLVED) {
            cast(p.spells, p.elements);
            p.state = ProposalState.EXECUTED;
        } else {
            delete p.spells;
            delete p.elements;
            p.state = ProposalState.DROPPED;
        }

        emit Executed(proposalId);
    }

    /**
     * @notice  Council의 투표 수량에 따라, 긴급하게 통과 시켜야 하는 제안 데이터
     * @dev     카운슬만 호출 가능 함
     * @param   spells 실행 커맨드 값
     * @param   elements 커맨드가 사용할 엘리먼츠 값
     */
    function emergencyExecute(bytes32[] calldata spells, bytes[] calldata elements) external onlyCouncil {
        unchecked {
            nonce++;
        }
        cast(spells, elements);
    }

    /**
     * @notice  연결된 카운슬을 다른 카운슬 컨트랙트로 변경한다. 이때 일반적인 EOA로는 이관할 수 없습니다.
     * @param   councilAddr 카운슬 컨트랙트를 구현하는 주소
     */
    function changeCouncil(address councilAddr) external onlyGov {
        try IERC165(councilAddr).supportsInterface(type(ICouncil).interfaceId) returns (bool support) {
            if (!support) {
                revert Governance__NotCouncilContract(councilAddr);
            }
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert Governance__NoneERC165Interface(councilAddr);
            } else {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
        }
        if (!IERC165(councilAddr).supportsInterface(type(ICouncil).interfaceId)) {
            revert Governance__NotCouncilContract(councilAddr);
        }
        council = councilAddr;
    }

    /**
     * @notice  Governance의 실행 지연 시간을 변경합니다. 다만, Minimum과 Maximum 지연 시간 사이에서 가능합니다.
     * @param   executeDelay 설정할 지연 시간
     */
    function changeDelay(uint32 executeDelay) external onlyGov {
        setDelay(executeDelay, MINIMUM_DELAY, MAXIMUM_DELAY);
    }

    /**
     * @notice  현재 연결되어 있는 카운슬을 다른 주소로 변경하며, 이때 어떤 주소로든 이관할 수 있다.
     */
    function emergencyCouncil(address councilAddr) external onlyGov {
        if (council == councilAddr || councilAddr == address(this)) {
            revert Governance__InvalidAddress(councilAddr);
        }
        council = councilAddr;
    }

    /**
     * @notice  Council이 EOA로 등록된 경우, EOA가 Governance를 대신하여 Off-chain 투표를 수행하도록 합니다.
     * TODO: signature를 calldata로 변경하고, 아래 전체 과정 어셈블리로 작성
     */
    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4 magicValue) {
        uint8 v;
        bytes32 r;
        bytes32 s;

        if (signature.length == 65) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                r := mload(add(signature, 32))
                s := mload(add(signature, 64))
                v := byte(0, mload(add(signature, 96)))
            }
        } else if (signature.length == 64) {
            bytes32 vs;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                r := mload(add(signature, 32))
                vs := mload(add(signature, 64))
                s := and(vs, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
            }
            unchecked {
                v = 27 + uint8(uint256(vs) >> 255);
            }
        } else {
            revert Governance__InvalidSignature();
        }

        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert Governance__InvalidSignature_S();
        }

        if (v != 27 && v != 28) {
            revert Governance__InvalidSignature_V();
        }

        address signer = ecrecover(digest, v, r, s);

        if (council == signer && signer != address(0)) {
            magicValue = 0x1626ba7e; // bytes4(keccak256("isValidSignature(bytes32,bytes)"))
        } else {
            magicValue = 0xffffffff;
        }
    }

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return IERC721TokenReceiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155TokenReceiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155TokenReceiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721TokenReceiver).interfaceId
            || interfaceId == type(IERC1155TokenReceiver).interfaceId;
    }
}
