/**
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
pragma solidity ^0.8.0;

import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Pool.sol";
import "UniswapV3Pack/v3-core/interfaces/IUniswapV3Factory.sol";
import "UniswapV3Pack/v3-core/interfaces/callback/IUniswapV3MintCallback.sol";
import "UniswapV3Pack/v3-core/libraries/TickMath.sol";
import "UniswapV3Pack/v3-periphery/interfaces/ISwapRouter.sol";
import "UniswapV3Pack/v3-periphery/interfaces/IQuoterV2.sol";
import {PositionKey} from "UniswapV3Pack/v3-periphery/libraries/PositionKey.sol";
import {LiquidityAmounts} from "UniswapV3Pack/v3-periphery/libraries/LiquidityAmounts.sol";
import "@beandao/contracts/interfaces/IERC165.sol";
import "@beandao/contracts/library/Initializer.sol";
import "./Math.sol";
import "./IGovernance.sol";
import "./ICouncil.sol";

error Council__NotReachedDelay();

error Council__NotReachedQuorum();

error Council__NotResolvable(bytes32 proposalId);

error Council__AlreadyProposed(bytes32 proposalId);

error Council__NotActiveProposal(bytes32 proposalId);

error Council__AlreadyVoted(bytes32 proposalId, bool vote);

error NotEnoughVotes();

error NotAllowedAddress(address delegatee);

/**
 * @title Council
 * @notice 투표권과 투표 정보를 컨트롤하는 컨트랙트. 거버넌스 정보는 이곳에 저장하지 않으며 거버넌스가 신뢰할 Council이 있음
 * 투표는 최대 255개의 타입을 가질 수 있으며, 타입마다 해석의 방식을 지정할 수 있다.
 */
contract Council is IERC165, ICouncil {
    string public constant version = "1";
    address public constant UNIV3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address public constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNIV3_QUOTOR_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint256 internal constant DUST_THRESHOLD = 1e6;
    bytes32 public immutable positionKey;
    address public immutable token0;
    address public immutable token1;
    address public immutable pool;
    int24 public immutable lowerTick;
    int24 public immutable upperTick;
    uint24 public immutable fee;

    Slot public slot;
    mapping(bytes32 => Proposal) public proposals;
    mapping(address => uint256) public balances;
    mapping(address => address) public delegates;
    mapping(address => WithdrawPoint) public withdraws;
    mapping(address => Checkpoint[]) checkpoints;
    Checkpoint[] totalCheckpoints;

    event Delegate(address to, uint256 prevVotes, uint256 nextVotes);

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert();
        _;
    }

    /**
     * @notice  컨트랙트를 초기화 하기 위한 함수이며, 단 한 번만 실행이 가능합니다.
     * @param   proposalQuorum 제안서를 만들기 위한 제안 임계 백분율, 최대 10000
     * @param   emergencyQuorum 긴급 제안서를 통과 시키기 위한 임계 백분율, 최대 10000
     * @param   voteQuorum 제안서를 통과시키기 위한 임계 백분율, 최대 10000
     * @param   voteStartDelay 제안서의 투표 시작 지연 값, 단위 초
     * @param   votePeriod 제안서의 투표 기간, 단위 초
     * @param   voteChangableDelay 투표를 변경할 때 지연 값, 단위 초
     * @param   token0Addr Uniswap V3 Pool의 페어로 구성될 두 개의 토큰 중 하나
     * @param   token1Addr Uniswap V3 Pool의 페어로 구성될 두 개의 토큰 중 하나
     * @param   feeAmount Uniswap V3 Pool로 구성될 수수료 등급
     * @param   initialSqrtPriceX96 유동성 풀의 초기 가격
     * @param   lowerLimitTick 유동성 풀이 가지는 최저 틱
     * @param   upperLimitTick 유동성 풀이 가지는 높은 틱
     */
    constructor(
        uint16 proposalQuorum,
        uint16 voteQuorum,
        uint16 emergencyQuorum,
        uint32 voteStartDelay,
        uint32 votePeriod,
        uint32 voteChangableDelay,
        uint32 withdrawDelay,
        address token0Addr,
        address token1Addr,
        uint24 feeAmount,
        uint160 initialSqrtPriceX96,
        int24 lowerLimitTick,
        int24 upperLimitTick
    ) {
        require(proposalQuorum <= 1e4);
        require(voteQuorum <= 1e4);
        require(emergencyQuorum <= 1e4);
        (
            slot.proposalQuorum,
            slot.voteQuorum,
            slot.emergencyQuorum,
            slot.voteStartDelay,
            slot.votePeriod,
            slot.voteChangableDelay,
            slot.withdrawDelay
        ) = (
            proposalQuorum,
            voteQuorum,
            emergencyQuorum,
            voteStartDelay,
            votePeriod,
            voteChangableDelay,
            withdrawDelay
        );

        (fee) = (feeAmount);

        address tmppool = IUniswapV3Factory(UNIV3_FACTORY).getPool(token0Addr, token1Addr, feeAmount);
        pool = tmppool == address(0)
            ? IUniswapV3Factory(UNIV3_FACTORY).createPool(token0Addr, token1Addr, feeAmount)
            : tmppool;
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) {
            IUniswapV3Pool(pool).initialize(initialSqrtPriceX96);
        }
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();

        unchecked {
            // validate tick
            lowerLimitTick = (lowerLimitTick % tickSpacing) != 0
                ? lowerLimitTick - (lowerLimitTick % tickSpacing) + (lowerLimitTick < 0 ? -tickSpacing : tickSpacing)
                : lowerLimitTick;
            upperLimitTick = (upperLimitTick % tickSpacing) != 0
                ? upperLimitTick - (upperLimitTick % tickSpacing) + (upperLimitTick < 0 ? -tickSpacing : tickSpacing)
                : upperLimitTick;
        }
        (lowerTick, upperTick) = lowerLimitTick > upperLimitTick
            ? (upperLimitTick, lowerLimitTick)
            : (lowerLimitTick, upperLimitTick);
        (token0, token1) = token0Addr > token1Addr ? (token1Addr, token0Addr) : (token0Addr, token1Addr);
        positionKey = PositionKey.compute(address(this), lowerTick, upperTick);
    }

    /**
     * @notice 기본적으로 ETH는 받지 않도록 설정
     */
    receive() external payable {
        revert();
    }

    /**
     * @notice  두 개의 토큰을 이용하여, 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다.
     * @param   params token0과 token1의 수량과 최소한 추가되어야 할 수량 값
     */
    function stake(StakeParam calldata params) external checkDeadline(params.deadline) {
        // 둘 다 0으로 들어오는 경우 실패
        if (params.amount0Desired == 0 && params.amount1Desired == 0) {
            revert();
        }

        address currentDelegatee = delegates[msg.sender];
        // 현재 포지션에 있는 유동성
        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        // 현재 Pool의 가격
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        // Pool에 더해야 하는 유동성 계산
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            params.amount0Desired,
            params.amount1Desired
        );

        if (liquidity == 0) {
            revert();
        }

        // 해당 시점에서, Council이 가지고 있는 토큰을 등록함
        (uint256 amount0, uint256 amount1) = IUniswapV3Pool(pool).mint(
            address(this),
            lowerTick,
            upperTick,
            liquidity,
            abi.encode(msg.sender)
        );

        // 실제로 추가된 토큰 수량 체크
        if (amount0 < params.amount0Min && amount1 < params.amount1Min) {
            revert();
        }

        // added totalShare
        uint256 existingShareSupply = latestTotalSupply();

        uint256 shares;
        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        unchecked {
            balances[msg.sender] += shares;
        }

        // 누군가에게 위임을 했다면,
        if (currentDelegatee != msg.sender && currentDelegatee != address(0)) {
            // 추가된 수량만큼 기존 위임자에게 위임 수량 증가.
            delegateVotes(address(0), currentDelegatee, shares);
        } else {
            delegateVotes(address(0), msg.sender, shares);
            delegates[msg.sender] = msg.sender;
        }

        // 총 위임량 업데이트
        writeCheckpoint(totalCheckpoints, _add, shares);
    }

    /**
     * @notice  하나의 토큰만 예치하여, swap을 통해 희석한 다음 투표권으로 변환합니다.
     * @dev     추가되어야 할 수량값은 급격하게 가격이 변동하는 경우를 대비한 값이 입력되어야 합니다. param에 사용될 값은 `getSingleSidedAmount`
     * 함수로 미리 계산되어야 합니다.
     * @param   params 추가할 총 토큰 수량, 교환할 토큰 수량, 최소로 교환된 토큰 수량, 입력되는 토큰이
     */
    function stake(StakeSingleParam calldata params) external checkDeadline(params.deadline) {
        if (params.amountInForSwap > params.amountIn) {
            revert();
        }

        address currentDelegatee = delegates[msg.sender];
        (address tokenIn, address tokenOut) = params.isAmountIn0 ? (token0, token1) : (token1, token0);

        safeTransferFrom(tokenIn, msg.sender, address(this), params.amountIn);

        safeApprove(tokenIn, UNIV3_ROUTER, params.amountInForSwap);

        uint256 amountOut = ISwapRouter(UNIV3_ROUTER).exactInput(
            ISwapRouter.ExactInputParams({
                path: abi.encodePacked(tokenIn, fee, tokenOut),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: params.amountInForSwap,
                amountOutMinimum: params.amountOutMin
            })
        );

        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();

        (uint256 amount0, uint256 amount1) = params.isAmountIn0
            ? (params.amountIn - params.amountInForSwap, amountOut)
            : (amountOut, params.amountIn - params.amountInForSwap);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick),
            amount0,
            amount1
        );

        if (liquidity == 0) {
            revert();
        }

        // this stage for token transfered
        (amount0, amount1) = IUniswapV3Pool(pool).mint(
            address(this),
            lowerTick,
            upperTick,
            liquidity,
            abi.encode(this)
        );

        // added totalShare
        uint256 existingShareSupply = latestTotalSupply();
        uint256 shares;
        if (existingShareSupply == 0) {
            shares = liquidity;
        } else {
            shares = Math.mulDiv(existingShareSupply, liquidity, existingLiquidity);
        }

        unchecked {
            balances[msg.sender] += shares;
        }

        // 누군가에게 위임을 했다면,
        if (currentDelegatee != msg.sender && currentDelegatee != address(0)) {
            // 추가된 수량만큼 기존 위임자에게 위임 수량 증가.
            delegateVotes(address(0), currentDelegatee, shares);
        } else {
            delegateVotes(address(0), msg.sender, shares);
            delegates[msg.sender] = msg.sender;
        }

        // 총 위임량 업데이트
        writeCheckpoint(totalCheckpoints, _add, shares);

        // 남아있는 dust 전송
        {
            (bool success, bytes memory data) = token0.staticcall(
                abi.encodeWithSignature("balanceOf(address)", address(this))
            );
            require(success && data.length >= 32);
            uint256 dust0 = abi.decode(data, (uint256));

            (success, data) = token1.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
            require(success && data.length >= 32);
            uint256 dust1 = abi.decode(data, (uint256));

            if (dust0 != 0) {
                safeTransfer(token0, msg.sender, dust0);
            }
            if (dust1 != 0) {
                safeTransfer(token1, msg.sender, dust1);
            }
        }
    }

    /**
     * @notice  투표권 만큼 예치를 해지합니다. 이미 해지중인 투표권이 있다면, 마지막에 해지한 시점에서 출금 기간 동안 지연됩니다.
     * @dev     0이 입력되는 경우 실패하며, 저장되어 있는 투표권보다 많은 수량이 입력되어도 실패합니다.
     * @param   shares 투표권 수량
     */
    function unstake(uint256 shares) external {
        // 0이 입력되는 경우에 실패되어야 합니다.
        if (shares == 0) {
            revert();
        }

        // 현재 위임중인 물량과 현재 마지막 총 수량
        (address currentDelegatee, uint256 latestBalance) = (delegates[msg.sender], balances[msg.sender]);

        // 투표권이 현재 값보다 크다면 실패되어야 합니다.
        if (shares > latestBalance) {
            revert();
        }

        // 체크 포인트의 길이에 따라 마지막 총 수량을 가져옵니다.
        uint256 currentTotalSupply = latestTotalSupply();
        // 유니스왑 풀에 있는 총 유동성을 가져옵니다.
        (uint128 existingLiquidity, , , , ) = IUniswapV3Pool(pool).positions(positionKey);
        // 투표권 수량에 따라 제거할 유동성을 계산합니다.
        uint128 removedLiquidity = uint128(Math.mulDiv(existingLiquidity, shares, currentTotalSupply));
        // 유동성 해제
        (uint256 amount0, uint256 amount1) = IUniswapV3Pool(pool).burn(lowerTick, upperTick, removedLiquidity);
        // 해제된 유동성 Council로 전송
        (amount0, amount1) = IUniswapV3Pool(pool).collect(
            address(this),
            lowerTick,
            upperTick,
            uint128(amount0),
            uint128(amount1)
        );

        // 저장 되어 있는 출금 정보 메모리에 저장
        WithdrawPoint memory wp = withdraws[msg.sender];
        // 출금정보 업데이트
        if (wp.timestamp == 0) {
            (wp.amount0, wp.amount1, wp.timestamp) = (uint96(amount0), uint96(amount1), uint64(block.timestamp));
        } else {
            unchecked {
                (wp.amount0, wp.amount1, wp.timestamp) = (
                    wp.amount0 + uint96(amount0),
                    wp.amount1 + uint96(amount1),
                    uint64(block.timestamp)
                );
            }
        }
        // 업데이트 된 출금정보 저장
        withdraws[msg.sender] = wp;

        // 잔액이 0이라면 기존 밸런스 모두 삭제.
        if (latestBalance == shares) {
            delete balances[msg.sender];
            delete delegates[msg.sender];
        } else {
            // 잔액이 남았다면 차감만 함
            balances[msg.sender] -= shares;
        }

        // 현재 위임에서 share 만큼 삭감
        delegateVotes(currentDelegatee, address(0), shares);
        // 총 체크포인트 업데이트
        writeCheckpoint(totalCheckpoints, _sub, shares);
    }

    /**
     * @notice  투표권을 되돌린 다음, 되돌린 투표권에 따른 토큰 수량을 전송합니다.
     * @dev     해당 함수는 누구나 호출할 수 있으며, parameter에 들어가는 주소가 이미 투표권을 되돌렸어야 합니다.
     * @param   queue 투표권을 되돌린 지갑 주소
     */
    function withdraw(address queue) external {
        WithdrawPoint memory wp = withdraws[msg.sender];
        if (wp.timestamp == 0) {
            revert();
        }
        unchecked {
            if (wp.timestamp + slot.withdrawDelay > uint64(block.timestamp)) {
                revert();
            }
        }

        safeTransfer(token0, queue, wp.amount0);
        safeTransfer(token1, queue, wp.amount1);
        delete withdraws[msg.sender];
    }

    /**
     * @notice  예치된 투표권을 특정 주소로 위임합니다.
     * @dev     투표권 소유자만 호출하여 사용할 수 있습니다.
     * @param   delegatee 위임하고자 하는 대상의 주소
     */
    function delegate(address delegatee) external {
        if (delegatee == address(0)) {
            revert NotAllowedAddress(delegatee);
        }
        (address currentDelegate, uint256 latestBalance) = (delegates[msg.sender], balances[msg.sender]);

        if (latestBalance == 0) {
            revert NotEnoughVotes();
        }

        if (currentDelegate != delegatee) {
            delegateVotes(currentDelegate, delegatee, latestBalance);
            delegates[msg.sender] = delegatee;
        }
    }

    /**
     * @notice  토큰을 하나만 주입했을 때, 얻을 수 있는 투표권의 수치와 얼마만큼을 교환하는데 사용하는지 반환합니다.
     * @dev     해당 함수는 상태를 변경하지 않고 많은 반복문을 이용하기 때문에, On-chain Tx로 사용되기에 적합하지 않습니다.
     * 이 컨트랙트를 수정하여 사용하는 경우, 토큰이 지원하는 소수점에 따라 Dust 수량을 재조정할 필요가 있습니다.
     * @param   amountIn        주입하고자 하는 토큰 수량
     * @param   isAmountIn0     주입하고자 하는 토큰이 token0 라면 활성화
     * @return  liquidity       하나의 토큰을 주입하고서 반환되는 투표권 수량
     * @return  amountForSwap   주입하고자 하는 토큰 수량에서 실제로 교환되는데 사용되는 토큰 수량
     */
    function getSingleSidedAmount(uint256 amountIn, bool isAmountIn0)
        external
        returns (uint128 liquidity, uint256 amountForSwap)
    {
        (uint160 lowerSqrtPrice, uint160 upperSqrtPrice) = (
            TickMath.getSqrtRatioAtTick(lowerTick),
            TickMath.getSqrtRatioAtTick(upperTick)
        );

        (address tokenIn, address tokenOut) = isAmountIn0 ? (token0, token1) : (token1, token0);

        amountForSwap = amountIn / 2;
        uint256 i; // Cur binary search iteration
        (uint256 low, uint256 high) = (0, amountIn);
        uint256 amountOutRecv;
        uint160 sqrtRatioX96; // current price
        uint256 leftoverAmount0;
        uint256 leftoverAmount1;

        while (i != 128) {
            (amountOutRecv, sqrtRatioX96, , ) = IQuoterV2(UNIV3_QUOTOR_V2).quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountForSwap,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            );

            uint256 amountInPostSwap = amountIn - amountForSwap;

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                lowerSqrtPrice,
                upperSqrtPrice,
                isAmountIn0 ? amountInPostSwap : amountOutRecv,
                isAmountIn0 ? amountOutRecv : amountInPostSwap
            );

            // Get the amounts needed for post swap end sqrt ratio end state
            (uint256 lpAmount0, uint256 lpAmount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                lowerSqrtPrice,
                upperSqrtPrice,
                liquidity
            );

            // Calculate leftover amounts with Trimming some dust
            if (isAmountIn0) {
                leftoverAmount0 = ((amountInPostSwap - lpAmount0) / 100) * 100;
                leftoverAmount1 = ((amountOutRecv - lpAmount1) / 100) * 100;
            } else {
                leftoverAmount0 = ((amountOutRecv - lpAmount0) / 100) * 100;
                leftoverAmount1 = ((amountInPostSwap - lpAmount1) / 100) * 100;
            }

            // Termination condition, we approximated enough
            if (leftoverAmount0 <= DUST_THRESHOLD && leftoverAmount1 <= DUST_THRESHOLD) {
                break;
            }

            if (isAmountIn0) {
                if (leftoverAmount0 > 0) {
                    (low, amountForSwap, high) = (amountForSwap, (high + amountForSwap) / 2, high);
                } else if (leftoverAmount1 > 0) {
                    (low, amountForSwap, high) = (low, (low + amountForSwap) / 2, amountForSwap);
                } else {
                    break;
                }
            } else {
                if (leftoverAmount1 > 0) {
                    (low, amountForSwap, high) = (amountForSwap, (high + amountForSwap) / 2, high);
                } else if (leftoverAmount0 > 0) {
                    (low, amountForSwap, high) = (low, (low + amountForSwap) / 2, amountForSwap);
                } else {
                    break;
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  Uniswap Pool에서 해당 컨트랙트로 직접적으로 호출하는 콜백 함수
     * @dev     일반적인 이용자가 해당 함수를 직접적으로 호출하는 경우에 토큰이 Pool로 이동하기 때문에, 일반적으로 호출하는 경우에 실패합니다.
     * @param   amount0Owed Uniswap Pool에서 요구하는 유동성을 추가할 token0의 수량
     * @param   amount1Owed Uniswap Pool에서 요구하는 유동성을 추가할 token1의 수량
     * @param   data        Uniswap Pool에서 전송된 bytes화 데이터, 해당 컨트랙트에서는 주소로 해석 됩니다.
     */
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        if (msg.sender != pool) {
            revert();
        }
        address from = abi.decode(data, (address));
        if (from != address(this)) {
            if (amount0Owed != 0) {
                safeTransferFrom(token0, from, pool, amount0Owed);
            }
            if (amount1Owed != 0) {
                safeTransferFrom(token1, from, pool, amount1Owed);
            }
        } else if (from == address(this)) {
            if (amount0Owed != 0) {
                safeTransfer(token0, pool, amount0Owed);
            }
            if (amount1Owed != 0) {
                safeTransfer(token1, pool, amount1Owed);
            }
        }
    }

    /**
     * @notice  특정 주소의 투표권 정보가 업데이트 된 길이를 반환합니다.
     * @param   account 조회할 지갑 주소
     */
    function numCheckpoints(address account) public view returns (uint32) {
        return uint32(checkpoints[account].length);
    }

    /**
     * @notice  BlockNumber를 기준으로, target의 정량적인 투표권을 가져옵니다.
     * @dev     내부에서 사용되는
     * @param   target 대상이 되는 주소
     * @param   blockNumber 기반이 되는 블록 숫자
     * @return  votes 투표 권한
     */
    function getPriorVotes(address target, uint256 blockNumber) public view returns (uint256 votes) {
        if (blockNumber > block.number) {
            revert();
        }
        votes = _checkpointsLookup(checkpoints[target], blockNumber);
    }

    /**
     * @notice  블록 숫자를 기준으로, target의 투표권을 비율화 하여 가져옵니다.
     * @param   target 대상이 되는 주소
     * @param   blockNumber 기반이 되는 블록 숫자
     * @return  rate 해당 지갑 주소가 가지는 투표권 비율
     */
    function getPriorRate(address target, uint256 blockNumber) public view returns (uint256 rate) {
        if (blockNumber > block.number) {
            revert();
        }
        rate =
            (_checkpointsLookup(checkpoints[target], blockNumber) * 1e4) /
            _checkpointsLookup(totalCheckpoints, blockNumber);
    }

    /**
     * @notice  블록 숫자를 기준으로, 특정 수치의 투표권을 총 투표권의 비율로 계산하는 함수
     * @param   votes 계산하고자 하는 투표권 수량
     * @param   blockNumber 기반이 되는 블록 숫자
     * @return  rate 해당 투표권 수량에 따른 투표권 비율
     */
    function getVotesToRate(uint256 votes, uint256 blockNumber) public view returns (uint256 rate) {
        if (blockNumber > block.number) {
            revert();
        }
        rate = (votes * 1e4) / _checkpointsLookup(totalCheckpoints, blockNumber);
    }

    /**
     * @notice  입력된 블록 숫자를 기준하여, 총 투표권을 반환합니다.
     * @param   blockNumber 기반이 되는 블록 숫자
     * @return  totalVotes 해당 블록의 총 투표권
     */
    function getPriorTotalSupply(uint256 blockNumber) public view returns (uint256 totalVotes) {
        if (blockNumber > block.number) {
            revert();
        }
        totalVotes = _checkpointsLookup(totalCheckpoints, blockNumber);
    }

    /**
     * @notice  특정 주소의 총 예치된 유동성을 반환합니다.
     * @param   target 대상이 되는 주소
     * @return  balance 반횐되는 예치된 유동성 수량
     */
    function balanceOf(address target) public view returns (uint256 balance) {
        balance = balances[target];
    }

    /**
     * @notice  특정 주소의 총 투표권을 반환합니다.
     * @param   target 대상이 되는 주소
     * @return  votes 반횐되는 투표권
     */
    function voteOf(address target) public view returns (uint256 votes) {
        uint256 length = checkpoints[target].length;
        unchecked {
            if (length != 0) {
                votes = checkpoints[target][length - 1].votes;
            }
        }
    }

    /**
     * @notice  특정 주소가 투표권을 위임하고 있는 주소를 반환합니다.
     * @param   target 대상이 되는 주소
     * @return  delegatee 위임한 대상의 주소
     */
    function getDelegate(address target) public view returns (address delegatee) {
        delegatee = delegates[target];
    }

    /**
     * @notice  총 투표권 수량을 반환합니다.
     * @return  amount 총 투표권 수량
     */
    function totalSupply() public view returns (uint256 amount) {
        uint256 length = totalCheckpoints.length;
        unchecked {
            if (length != 0) {
                amount = totalCheckpoints[length - 1].votes;
            }
        }
    }

    /**
     * @notice  투표권을 구성하는 두 개의 토큰 주소를 반환합니다.
     */
    function getTokens() public view returns (address, address) {
        return (token0, token1);
    }

    /**
     * @notice  amount 만큼, 투표권을 from으로 부터 to로 이관합니다.
     * @dev     from이 Zero Address라면, 새로운 amount를 등록하는 것이며, to가 Zero Address라면 기존에 있던 amount를 감소시킵니다.
     * @param   from 위임을 부여할 대상
     * @param   to 위임이 이전될 대상
     * @param   amount 위임 수량
     */
    function delegateVotes(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (from != to && amount != 0) {
            if (from != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(checkpoints[from], _sub, amount);
                emit Delegate(from, oldWeight, newWeight);
            }

            if (to != address(0)) {
                (uint256 oldWeight, uint256 newWeight) = writeCheckpoint(checkpoints[to], _add, amount);
                emit Delegate(to, oldWeight, newWeight);
            }
        }
    }

    /**
     * @notice 거버넌스로 제안서를 보내는 역할을 하며, 해당 컨트랙트에서도 투표만을 위한 제안서를 동일하게 생성한다.
     * @param governance Council이 목표로 하는 거버넌스 컨트랙트 주소
     * @param spells GPE-command array
     * @param elements variable for commands array
     */
    function propose(
        address governance,
        bytes32[] calldata spells,
        bytes[] calldata elements
    ) external {
        Slot memory s = slot;
        // 현재로 부터 한 블럭 이전 기준으로 msg.sender의 제안 권한이 최소 쿼럼을 만족하는지 체크
        if (getPriorRate(msg.sender, block.number - 1) < s.proposalQuorum) {
            revert Council__NotReachedQuorum();
        }

        // 투표 시작 지연 추가
        uint32 start = uint32(block.timestamp) + s.voteStartDelay;
        uint32 end = start + s.votePeriod;
        // 거버넌스에 등록할 proposal 정보
        IGovernance.ProposalParams memory params = IGovernance.ProposalParams({
            proposer: msg.sender,
            spells: spells,
            elements: elements
        });

        // 거버넌스 컨트랙트에 proposal 등록
        bytes32 proposalId = IGovernance(governance).propose(params);
        // 반횐된 uid에 대해 council 버전의 proposal 저장.
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 한번도 사용되지 않은 유니크 아이디인지 확인
        if (state != ProposalState.UNKNOWN) {
            revert Council__AlreadyProposed(proposalId);
        }

        (p.governance, p.startTime, p.endTime, p.blockNumber, p.spells, p.elements) = (
            governance,
            start,
            end,
            uint32(block.number), // block number for Verification.
            spells,
            elements
        );
        emit Proposed(proposalId);
    }

    /**
     * TODO: 전용 구조체, 전용 이벤트, 날짜 uint8로 변경
     * @notice 응급 제안서를 처리하기 위한 전용함수
     * @param governance Council이 목표로 하는 거버넌스 컨트랙트 주소
     * @param spells GPE-command array
     * @param elements variable for commands array
     */
    function emergencyProposal(
        address governance,
        bytes32[] memory spells,
        bytes[] calldata elements
    ) external {}

    /**
     * @notice 제안서에 투표를 하며, 투표 상태가 활성화 되어 있어야만 가능 함.
     * 투표를 변경하는 경우 변경에 필요한 지연이 충분히 지나고, 이전 투표를 새 투표로 옮김
     * @param proposalId 제안서의 고유 아이디
     * @param support 해시 형태로, 어떤 값에 투표할 것인지 -> 값의 스펙트럼이 넓은 이유는 off-chain vote를 위한 것
     */
    function vote(bytes32 proposalId, bool support) external {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        // 존재하는 Proposal인지 & 활성 상태인지 확인
        if (state != ProposalState.ACTIVE) {
            revert Council__NotActiveProposal(proposalId);
        }
        // 기록된 블록의 - 1 기준으로 투표권 확인
        uint256 power = getPriorVotes(msg.sender, p.blockNumber - 1);
        // 제안서의 현재 투표 상태
        Vote storage v = p.votes[msg.sender];
        // timestamp 0인지 체크 -> 처음 투표 과정(support 에 따라서 파워 기록, votes에 기록)
        if (v.ts == 0) {
            v.ts = uint32(block.timestamp);
            v.state = support ? VoteState.YEA : VoteState.NAY;
            p.yea += support ? uint96(power) : 0;
            p.nay += support ? 0 : uint96(power);
            p.totalVotes += uint96(power);
        } else {
            // 투표 변경 딜레이 확인
            if ((v.ts + slot.voteChangableDelay) > uint32(block.timestamp)) {
                revert Council__NotReachedDelay();
            }
            if (!support ? p.nay > 0 : p.yea > 0) {
                revert Council__AlreadyVoted(proposalId, support);
            }
            // 새로운 타임스탬프 기록
            v.ts = uint32(block.timestamp);
            // 이전 투표 파워 삭제
            p.yea -= support ? 0 : uint96(power);
            p.nay -= support ? uint96(power) : 0;
            // 새로운 투표 상태 업데이트
            v.state = support ? VoteState.YEA : VoteState.NAY;
            // 새로운 투표 파워 업데이트
            p.yea += support ? uint96(power) : 0;
            p.nay += support ? 0 : uint96(power);
        }
        emit Voted(msg.sender, proposalId, power);
    }

    /**
     * @notice 투표 기간이 종료 되었을 때 투표 상태를 검증하여, 거버넌스로 투표 정보에 따른 실행 여부를 전송함.
     * @param proposalId 제안서의 고유 아이디
     * @return success 해당 제안서가 검증을 통과했는지 여부
     */
    function resolve(bytes32 proposalId) external returns (bool success) {
        (ProposalState state, Proposal storage p) = getProposalState(proposalId);
        if (state != ProposalState.STANDBY) {
            revert Council__NotResolvable(proposalId);
        }
        // 총 투표량이 쿼럼을 넘는지 체크
        if (getVotesToRate(p.totalVotes, p.blockNumber - 1) < slot.voteQuorum) {
            revert Council__NotReachedQuorum();
        }

        // yea > nay -> queued -> 거버넌스의 대기열에 등록
        // nay < yea -> leftout -> 거버넌스의 canceling
        (p.queued, p.leftout) = p.yea > p.nay
            ? (IGovernance(p.governance).approve(proposalId), false)
            : (false, IGovernance(p.governance).drop(proposalId));
        success = true;
        emit Resolved(proposalId);
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(ICouncil).interfaceId || interfaceID == type(IERC165).interfaceId;
    }

    function getProposalState(bytes32 proposalId) internal view returns (ProposalState state, Proposal storage p) {
        p = proposals[proposalId];

        if (p.startTime == 0) {
            // 시작시간 0이면 등록되지 않은 제안서
            state = ProposalState.UNKNOWN;
        } else if (p.startTime > uint32(block.timestamp)) {
            // 제안서에 기록된 시작 시간이 현재 시간 보다 클 때: 투표 대기중
            state = ProposalState.PENDING;
        } else if (p.startTime <= uint32(block.timestamp) && p.endTime > uint32(block.timestamp)) {
            // 제안서에 기록된 시작 시간이 현재 시간보다 작으며, 종료 시간이 현재 시간보다 클 때: 투표 중
            state = ProposalState.ACTIVE;
        } else if (p.startTime < uint32(block.timestamp) && p.endTime <= uint32(block.timestamp)) {
            state = p.queued == true ? ProposalState.QUEUED : p.leftout == true
                ? ProposalState.LEFTOUT
                : ProposalState.STANDBY;
        }
    }

    function name() public pure returns (string memory) {
        // Council
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0x20, 0x20)
            mstore(0x47, 0x07436f756e63696c)
            return(0x20, 0x60)
        }
    }

    function latestTotalSupply() internal view returns (uint256 supply) {
        uint256 length = totalCheckpoints.length;
        unchecked {
            if (length != 0) {
                supply = totalCheckpoints[length - 1].votes;
            }
        }
    }

    /// @notice Modified from Gnosis
    /// (https://github.com/gnosis/gp-v2-contracts/blob/main/src/contracts/libraries/GPv2SafeERC20.sol)
    function safeTransferFrom(
        address tokenAddr,
        address from,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), from)
            mstore(add(freePointer, 36), to)
            mstore(add(freePointer, 68), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 100, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function safeTransfer(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)
            mstore(freePointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), to)
            mstore(add(freePointer, 36), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 68, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function safeApprove(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freePointer := mload(0x40)

            mstore(freePointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(freePointer, 4), to)
            mstore(add(freePointer, 36), amount)

            let callStatus := call(gas(), tokenAddr, 0, freePointer, 68, 0, 0)

            let returnDataSize := returndatasize()
            if iszero(callStatus) {
                // Copy the revert message into memory.
                returndatacopy(0, 0, returnDataSize)

                // Revert with the same message.
                revert(0, returnDataSize)
            }
            switch returnDataSize
            case 32 {
                // Copy the return data into memory.
                returndatacopy(0, 0, returnDataSize)

                // Set success to whether it returned true.
                success := iszero(iszero(mload(0)))
            }
            case 0 {
                // There was no return data.
                success := 1
            }
            default {
                // It returned some malformed input.
                success := 0
            }
        }
    }

    function _add(uint128 a, uint128 b) private pure returns (uint128) {
        return a + b;
    }

    function _sub(uint128 a, uint128 b) private pure returns (uint128) {
        return a - b;
    }

    /**
     * @notice  투표권을 업데이트하는데 사용하는 함수입니다.
     * @param   ckpts 업데이트 하고자 하는 Checkpoint 위치
     * @param   op function(uint128,uint128) 함수 포인터
     * @param   delta 증/경감하고자 하는 값
     */
    function writeCheckpoint(
        Checkpoint[] storage ckpts,
        function(uint128, uint128) view returns (uint128) op,
        uint256 delta
    ) internal returns (uint128 oldWeight, uint128 newWeight) {
        uint256 length = ckpts.length;
        oldWeight = length != 0 ? ckpts[length - 1].votes : 0;
        newWeight = op(oldWeight, uint128(delta));

        if (length > 0 && ckpts[length - 1].fromBlock == block.number) {
            ckpts[length - 1].votes = newWeight;
        } else {
            ckpts.push(Checkpoint({fromBlock: uint32(block.number), votes: newWeight}));
        }
    }

    /**
     * @notice  저장된 체크포인트에서 블록 숫자를 기반한 투표권을 가져오는 내부 함수
     * @dev     내장 함수입니다.
     * @param   ckpts 체크포인트 배열
     * @param   blockNumber 기준하는 블록 숫자
     * @return  votes 투표권 수량
     */
    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint256 votes) {
        uint256 high = ckpts.length;
        uint256 low = 0;
        uint256 mid;
        while (low < high) {
            unchecked {
                mid = ((low & high) + (low ^ high) / 2);
            }
            if (ckpts[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                unchecked {
                    low = mid + 1;
                }
            }
        }

        unchecked {
            votes = high != 0 ? ckpts[high - 1].votes : 0;
        }
    }
}
