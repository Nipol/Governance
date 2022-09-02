import { expect } from 'chai';
import { ethers } from 'hardhat';
import { BigNumber, constants, Contract, Signer } from 'ethers';
import { keccak256, defaultAbiCoder, Interface, parseEther } from 'ethers/lib/utils';

import UniswapV3FactoryABI from './UniswapV3FactoryABI.json';
import UniswapV3PoolABI from './UniswapV3PoolABI.json';

const day = BigNumber.from('60').mul('60').mul('24');
export async function latestTimestamp(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).timestamp;
}
export async function latestBlocknumber(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).number;
}

// ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);

enum CouncilErros {
  NOT_REACHED_DELAY = 'Council__NotReachedDelay',
  NOT_REACHED_QUORUM = 'Council__NotReachedQuorum',
  NOT_RESOLVABLE = 'Council__NotResolvable',
  NOT_ACTIVE_PROPOSAL = 'Council__NotActiveProposal',
  ALREADY_PROPOSED = 'Council__AlreadyProposed',
  ALREADY_VOTED = 'Council__AlreadyVoted',
}

const ONE = ethers.BigNumber.from(1);
const TWO = ethers.BigNumber.from(2);
const PRECISION = BigNumber.from('2').pow(BigNumber.from('96'));

const sqrt = (x: BigNumber): BigNumber => {
  let z = x.add(ONE).div(TWO);
  let y = x;
  while (z.sub(y).isNegative()) {
    y = z;
    z = x.div(z).add(z).div(TWO);
  }
  return y;
};

const encodePriceSqrt = (reserve1: BigNumber, reserve0: BigNumber): BigNumber => {
  return sqrt(reserve1.mul(PRECISION).mul(PRECISION).div(reserve0));
};

const encodePriceSqrtWithToken = (
  token0: Contract,
  token1: Contract,
  reserve0: BigNumber,
  reserve1: BigNumber,
): BigNumber => {
  if (BigNumber.from(token1.address).gt(BigNumber.from(token0.address))) {
    return encodePriceSqrt(reserve0, reserve1);
  }
  return encodePriceSqrt(reserve1, reserve0);
};

describe('Council', () => {
  let GovernanceMock: Contract;
  let Council: Contract;
  let BEAN: Contract;
  let WETH: Contract;
  let TickMath: Contract;
  let UniswapV3Factory: Contract;

  let wallet: Signer;
  let walletTo: Signer;
  let Dummy: Signer;

  let WalletAddress: string;
  let ToAddress: string;

  beforeEach(async () => {
    UniswapV3Factory = await ethers.getContractAt(UniswapV3FactoryABI, '0x1F98431c8aD98523631AE4a59f267346ea31F984');

    const accounts = await ethers.getSigners();
    [wallet, walletTo, Dummy] = accounts;
    WalletAddress = await wallet.getAddress();
    ToAddress = await walletTo.getAddress();

    TickMath = await (await ethers.getContractFactory('contracts/mocks/TickMathMock.sol:TickMathMock')).deploy();

    GovernanceMock = await (
      await ethers.getContractFactory('contracts/mocks/GovernanceMock.sol:GovernanceMock', wallet)
    ).deploy();

    BEAN = await (
      await ethers.getContractFactory('contracts/mocks/ERC20.sol:StandardToken', wallet)
    ).deploy('bean', 'bean', 18);
    await BEAN.mint(BigNumber.from('100000000000000000000000')); // 100개 생성
    await BEAN.mintTo(ToAddress, BigNumber.from('100000000000000000000000')); // 100개 생성

    WETH = await (
      await ethers.getContractFactory('contracts/mocks/ERC20.sol:StandardToken', wallet)
    ).deploy('weth', 'weth', 18);
    await WETH.mint(BigNumber.from('100000000000000000000')); // 100개 생성
    await WETH.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
  });

  describe('Deploy', () => {
    it('should be success', async () => {
      const initialPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.0001')).toString();
      const upperPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.1')).toString();

      let [lowerTick, upperTick] = [
        await TickMath.getTickAtSqrtRatio(initialPrice),
        await TickMath.getTickAtSqrtRatio(upperPrice),
      ];

      lowerTick = lowerTick < 0 ? lowerTick - 60 : lowerTick + 60;

      if (lowerTick > upperTick) {
        [lowerTick, upperTick] = [upperTick, lowerTick];
      }

      const ProposalQuorum = 1000;
      const VoteQuorum = 7000;
      const EmergencyQuorum = 9500;
      const voteStartDelay = 0;
      const votePeriod = 604800;
      const voteChangableDelay = 345600;
      const withdrawDelay = 60 * 60 * 24 * 7;

      Council = await (
        await ethers.getContractFactory('contracts/Council.sol:Council', wallet)
      ).deploy(
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
        WETH.address,
        BEAN.address,
        3000,
        initialPrice,
        lowerTick,
        upperTick,
      );

      expect(await Council.name()).equal('Council');
      expect(await Council.slot()).deep.equal([
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
      ]);
      const [token0Addr, token1Addr] = BigNumber.from(BEAN.address).lt(BigNumber.from(WETH.address))
        ? [BEAN.address, WETH.address]
        : [WETH.address, BEAN.address];
      expect(await Council.getTokens()).deep.equal([token0Addr, token1Addr]);
      expect(await Council.totalSupply()).equal('0');
    });

    it('should be success with already exist pool', async () => {
      await UniswapV3Factory.createPool(WETH.address, BEAN.address, 3000);
      const pool = await UniswapV3Factory.getPool(WETH.address, BEAN.address, 3000);

      const initialPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.0001')).toString();
      const upperPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.1')).toString();

      let [lowerTick, upperTick] = [
        await TickMath.getTickAtSqrtRatio(initialPrice),
        await TickMath.getTickAtSqrtRatio(upperPrice),
      ];

      lowerTick = lowerTick < 0 ? lowerTick - 60 : lowerTick + 60;

      if (lowerTick > upperTick) {
        [lowerTick, upperTick] = [upperTick, lowerTick];
      }

      const ProposalQuorum = 1000;
      const VoteQuorum = 7000;
      const EmergencyQuorum = 9500;
      const voteStartDelay = 0;
      const votePeriod = 604800;
      const voteChangableDelay = 345600;
      const withdrawDelay = 60 * 60 * 24 * 7;

      Council = await (
        await ethers.getContractFactory('contracts/Council.sol:Council', wallet)
      ).deploy(
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
        WETH.address,
        BEAN.address,
        3000,
        initialPrice,
        lowerTick,
        upperTick,
      );

      expect(await Council.name()).equal('Council');
      expect(await Council.slot()).deep.equal([
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
      ]);
      const [token0Addr, token1Addr] = BigNumber.from(BEAN.address).lt(BigNumber.from(WETH.address))
        ? [BEAN.address, WETH.address]
        : [WETH.address, BEAN.address];
      expect(await Council.getTokens()).deep.equal([token0Addr, token1Addr]);
      expect(await Council.totalSupply()).equal('0');
      expect(await Council.pool()).equal(pool);
    });

    it('should be success with already initialized pool', async () => {
      await UniswapV3Factory.createPool(WETH.address, BEAN.address, 3000);
      const pool = await UniswapV3Factory.getPool(WETH.address, BEAN.address, 3000);

      const initialPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.0001')).toString();
      const upperPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.1')).toString();

      await (await ethers.getContractAt(UniswapV3PoolABI, pool)).initialize(initialPrice);

      let [lowerTick, upperTick] = [
        await TickMath.getTickAtSqrtRatio(initialPrice),
        await TickMath.getTickAtSqrtRatio(upperPrice),
      ];

      lowerTick = lowerTick < 0 ? lowerTick - 60 : lowerTick + 60;

      if (lowerTick > upperTick) {
        [lowerTick, upperTick] = [upperTick, lowerTick];
      }

      const ProposalQuorum = 1000;
      const VoteQuorum = 7000;
      const EmergencyQuorum = 9500;
      const voteStartDelay = 0;
      const votePeriod = 604800;
      const voteChangableDelay = 345600;
      const withdrawDelay = 60 * 60 * 24 * 7;

      Council = await (
        await ethers.getContractFactory('contracts/Council.sol:Council', wallet)
      ).deploy(
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
        WETH.address,
        BEAN.address,
        3000,
        initialPrice,
        lowerTick,
        upperTick,
      );

      expect(await Council.name()).equal('Council');
      expect(await Council.slot()).deep.equal([
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
      ]);
      const [token0Addr, token1Addr] = BigNumber.from(BEAN.address).lt(BigNumber.from(WETH.address))
        ? [BEAN.address, WETH.address]
        : [WETH.address, BEAN.address];
      expect(await Council.getTokens()).deep.equal([token0Addr, token1Addr]);
      expect(await Council.totalSupply()).equal('0');
      expect(await Council.pool()).equal(pool);
    });
  });

  describe('#stake', () => {
    beforeEach(async () => {
      const initialPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.0001')).toString();
      const upperPrice = encodePriceSqrtWithToken(WETH, BEAN, parseEther('0.01'), parseEther('0.1')).toString();

      let [lowerTick, upperTick] = [
        await TickMath.getTickAtSqrtRatio(initialPrice),
        await TickMath.getTickAtSqrtRatio(upperPrice),
      ];

      lowerTick = lowerTick < 0 ? lowerTick - 60 : lowerTick + 60;

      if (lowerTick > upperTick) {
        [lowerTick, upperTick] = [upperTick, lowerTick];
      }

      const ProposalQuorum = 1000;
      const VoteQuorum = 7000;
      const EmergencyQuorum = 9500;
      const voteStartDelay = 0;
      const votePeriod = 604800;
      const voteChangableDelay = 345600;
      const withdrawDelay = 60 * 60 * 24 * 7;

      Council = await (
        await ethers.getContractFactory('contracts/Council.sol:Council', wallet)
      ).deploy(
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
        WETH.address,
        BEAN.address,
        3000,
        initialPrice,
        lowerTick,
        upperTick,
      );

      expect(await Council.name()).equal('Council');
      expect(await Council.slot()).deep.equal([
        ProposalQuorum,
        VoteQuorum,
        EmergencyQuorum,
        voteStartDelay,
        votePeriod,
        voteChangableDelay,
        withdrawDelay,
      ]);
      const [token0Addr, token1Addr] = BigNumber.from(BEAN.address).lt(BigNumber.from(WETH.address))
        ? [BEAN.address, WETH.address]
        : [WETH.address, BEAN.address];
      expect(await Council.getTokens()).deep.equal([token0Addr, token1Addr]);
      expect(await Council.totalSupply()).equal('0');
    });
  });

  // describe('#propose()', () => {
  //   let StakeCouncil: Contract;

  //   beforeEach(async () => {
  //     await Council.initialize(
  //       StakeModule.address, // 모듈 주소
  //       VoteModuleInitializer,
  //       BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
  //       BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
  //       BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
  //       '0', // 제안서 투표 시작 딜레이 0일
  //       '5', // 제안서 투표 기간 5일
  //       '10',
  //     );
  //     StakeCouncil = StakeModule.attach(Council.address);
  //     await Token.approve(Council.address, constants.MaxUint256);
  //     await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
  //     // await network.provider.send("evm_mine");
  //   });

  //   // it('rate test', async () => {
  //   //   await Token.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
  //   //   await StakeCouncil.stake(BigNumber.from('100000000000000000000')); // 100개 스테이크
  //   //   await StakeCouncil.connect(walletTo).stake(BigNumber.from('100000000000000000000')); // 100개 스테이크
  //   //   const number = await ethers.provider.getBlockNumber();
  //   //   console.log(await StakeCouncil.getPriorRate(WalletAddress, number - 1));
  //   //   console.log(await StakeCouncil.getPriorRate(ToAddress, number - 1));
  //   // });

  //   it('should be success propose', async () => {
  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     expect(
  //       await Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
  //     ).to.emit(Council, 'Proposed');
  //   });

  //   it('should be revert with not reached quorum', async () => {
  //     // 다른 계좌의 스테이킹
  //     await Token.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
  //     await StakeCouncil.connect(walletTo).stake(BigNumber.from('100000000000000000000')); // 100개 스테이크

  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     await expect(
  //       Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
  //     ).revertedWith(CouncilErros.NOT_REACHED_QUORUM);
  //   });

  //   it('should be revert with same proposalid', async () => {
  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     expect(
  //       await Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
  //     ).to.emit(Council, 'Proposed');
  //     await expect(
  //       Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
  //     ).revertedWith(CouncilErros.ALREADY_PROPOSED);
  //   });
  // });

  // describe('#vote()', () => {
  //   let StakeCouncil: Contract;
  //   let pid: String;
  //   let startTime: BigNumber;
  //   let blockNumber: number;

  //   beforeEach(async () => {
  //     pid = '0x00000000000000000000000000000000000000000000000000000000000000f1';

  //     await Council.initialize(
  //       StakeModule.address, // 모듈 주소
  //       VoteModuleInitializer,
  //       BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
  //       BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
  //       BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
  //       '0', // 제안서 투표 시작 딜레이 0일
  //       '10', // 제안서 투표 기간 5일
  //       '2', // 투표 변경에 필요한 기간 2일
  //     );
  //     StakeCouncil = StakeModule.attach(Council.address);

  //     await Token.approve(Council.address, constants.MaxUint256);
  //     await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     await StakeCouncil.connect(walletTo).stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     let now = await latestTimestamp();
  //     startTime = day.add(now);
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [startTime.toNumber()]);
  //     await Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']);
  //     blockNumber = await latestBlocknumber();
  //   });

  //   it('should be success with vote', async () => {
  //     await expect(Council.vote(pid, true))
  //       .to.emit(Council, 'Voted')
  //       .withArgs(WalletAddress, pid, '10000000000000000000');

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);
  //   });

  //   it('should be revert with not reached delay for change vote', async () => {
  //     await expect(Council.vote(pid, true))
  //       .to.emit(Council, 'Voted')
  //       .withArgs(WalletAddress, pid, '10000000000000000000');

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);

  //     await expect(Council.vote(pid, false)).revertedWith(CouncilErros.NOT_REACHED_DELAY);

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);
  //   });

  //   it('should be success with change vote', async () => {
  //     await expect(Council.vote(pid, true))
  //       .to.emit(Council, 'Voted')
  //       .withArgs(WalletAddress, pid, '10000000000000000000');

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);

  //     let now = await latestTimestamp();
  //     const nex = day.mul('2').add(now);
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [nex.toNumber()]);

  //     await expect(Council.vote(pid, false))
  //       .to.emit(Council, 'Voted')
  //       .withArgs(WalletAddress, pid, '10000000000000000000');

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);
  //   });

  //   it('should be revert with change vote for same', async () => {
  //     await expect(Council.vote(pid, true))
  //       .to.emit(Council, 'Voted')
  //       .withArgs(WalletAddress, pid, '10000000000000000000');

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);

  //     let now = await latestTimestamp();
  //     const nex = day.mul('2').add(now);
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [nex.toNumber()]);

  //     await expect(Council.vote(pid, true)).revertedWith(CouncilErros.ALREADY_VOTED);

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false,
  //       false,
  //     ]);
  //   });

  //   it('should be revert with non-exist pid', async () => {
  //     await expect(
  //       Council.vote('0xf0000000000000000000000000000000000000000000000000000000000000f2', true),
  //     ).revertedWith(CouncilErros.NOT_ACTIVE_PROPOSAL);
  //   });
  // });

  // describe('#resolve()', () => {
  //   let StakeCouncil: Contract;
  //   let pid: String;
  //   let startTime: BigNumber;
  //   let blockNumber: number;

  //   beforeEach(async () => {
  //     pid = '0x00000000000000000000000000000000000000000000000000000000000000f1';

  //     await Council.initialize(
  //       StakeModule.address, // 모듈 주소
  //       VoteModuleInitializer,
  //       BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
  //       BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
  //       BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
  //       '0', // 제안서 투표 시작 딜레이 0일
  //       '10', // 제안서 투표 기간 5일
  //       '2',
  //     );
  //     StakeCouncil = StakeModule.attach(Council.address);
  //     await Token.approve(Council.address, constants.MaxUint256);
  //     await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     await StakeCouncil.connect(walletTo).stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     await ethers.provider.send('evm_mine', []);

  //     let now = await latestTimestamp();
  //     startTime = day.add(now).add('1');
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [startTime.toNumber()]);

  //     await Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']);
  //     blockNumber = await latestBlocknumber();
  //   });

  //   it('should be success with not reached vote', async () => {
  //     await Council.vote(pid, true);

  //     // console.log(await StakeCouncil.getPriorPower(constants.AddressZero, blockNumber - 1));
  //     // console.log(await StakeCouncil.getPriorPower(WalletAddress, blockNumber - 1));
  //     // console.log(await StakeCouncil.getPriorPower(ToAddress, blockNumber - 1));

  //     let now = await latestTimestamp();
  //     const newTime = day.mul('10').add(now);
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [newTime.toNumber()]);

  //     await expect(Council.resolve(pid)).revertedWith(CouncilErros.NOT_REACHED_QUORUM);

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('10000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('10000000000000000000'),
  //       false, // queued
  //       false, //leftout
  //     ]);
  //   });

  //   it('should be success with reached vote', async () => {
  //     await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
  //     await Council.vote(pid, true);
  //     await Council.connect(walletTo).vote(pid, true);

  //     // console.log(await StakeCouncil.getPriorPower(constants.AddressZero, blockNumber - 1));
  //     // console.log(await StakeCouncil.getPriorPower(WalletAddress, blockNumber - 1));
  //     // console.log(await StakeCouncil.getPriorPower(ToAddress, blockNumber - 1));

  //     let now = await latestTimestamp();
  //     const newTime = day.mul('10').add(now);
  //     await ethers.provider.send('evm_setNextBlockTimestamp', [newTime.toNumber()]);

  //     await expect(Council.resolve(pid)).emit(Council, 'Resolved').withArgs(pid);

  //     expect(await Council.proposals(pid)).to.deep.equal([
  //       GovernanceMock.address,
  //       startTime.toNumber(),
  //       day.mul('10').add(startTime).toNumber(),
  //       startTime.toNumber(),
  //       blockNumber,
  //       0,
  //       BigNumber.from('20000000000000000000'),
  //       BigNumber.from('0'),
  //       BigNumber.from('20000000000000000000'),
  //       true,
  //       false, //leftout
  //     ]);
  //   });
  // });
});
