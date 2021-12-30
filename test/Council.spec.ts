import { expect } from 'chai';
import { ethers } from 'hardhat';
import { BigNumber, constants, Contract, Signer } from 'ethers';
import { keccak256, defaultAbiCoder } from 'ethers/lib/utils';
import { pid } from 'process';

const day = BigNumber.from('60').mul('60').mul('24');
export async function latestTimestamp(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).timestamp;
}
export async function latestBlocknumber(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).number;
}

describe.only('Council', () => {
  let Governance: Contract;
  let GovernanceMock: Contract;
  let Council: Contract;
  let StakeModule: Contract;
  let Token: Contract;

  let wallet: Signer;
  let walletTo: Signer;
  let Dummy: Signer;

  let WalletAddress: string;
  let ToAddress: string;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    [wallet, walletTo, Dummy] = accounts;
    WalletAddress = await wallet.getAddress();
    ToAddress = await walletTo.getAddress();

    Governance = await (await ethers.getContractFactory('contracts/Governance.sol:Governance', wallet)).deploy();
    GovernanceMock = await (
      await ethers.getContractFactory('contracts/mocks/GovernanceMock.sol:GovernanceMock', wallet)
    ).deploy();
    Council = await (await ethers.getContractFactory('contracts/Council.sol:Council', wallet)).deploy();
    const StakeModuleDeployer = await ethers.getContractFactory(
      'contracts/VoteModule/StakeModule.sol:StakeModule',
      wallet,
    );
    Token = await (
      await ethers.getContractFactory('contracts/mocks/ERC20.sol:StandardToken', wallet)
    ).deploy('bean', 'bean', 18);
    await Token.mint(BigNumber.from('100000000000000000000')); // 100개 생성
    await Token.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
    StakeModule = await StakeModuleDeployer.deploy(Token.address);
    // 초기화 시작
    const day = BigNumber.from('60').mul('60').mul('24');
    await Governance.initialize('bean the DAO', Council.address, day);
  });

  describe('#initialize()', () => {
    it('should be success', async () => {
      await Council.initialize(
        StakeModule.address, // 모듈 주소
        BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
        BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
        BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
        '0', // 제안서 투표 시작 딜레이 0일
        '5', // 제안서 투표 기간 5일
        '10',
      );

      expect(await Council.slot()).deep.equal([1000, 7000, 9500, 0, 5, 10, StakeModule.address]);
    });

    it('should be revert with invalid module', async () => {
      await expect(
        Council.initialize(
          ToAddress, // 모듈 주소
          BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
          BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
          BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
          '0', // 제안서 투표 시작 딜레이 0일
          '5', // 제안서 투표 기간 5일
          '10',
        ),
      ).reverted;
    });

    it('should be revert with invalid percentage range', async () => {
      await expect(
        Council.initialize(
          StakeModule.address, // 모듈 주소
          BigNumber.from('10001'), // proposal 제안 가능 수량 10.00%
          BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
          BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
          '0', // 제안서 투표 시작 딜레이 0일
          '5', // 제안서 투표 기간 5일
          '10',
        ),
      ).reverted;

      await expect(
        Council.initialize(
          StakeModule.address, // 모듈 주소
          BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
          BigNumber.from('10001'), // proposal 성공 기준 수량 70.00%
          BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
          '0', // 제안서 투표 시작 딜레이 0일
          '5', // 제안서 투표 기간 5일
          '10',
        ),
      ).reverted;

      await expect(
        Council.initialize(
          StakeModule.address, // 모듈 주소
          BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
          BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
          BigNumber.from('10001'), // emergency proposal 성공 기준 95.55%
          '0', // 제안서 투표 시작 딜레이 0일
          '5', // 제안서 투표 기간 5일
          '10',
        ),
      ).reverted;
    });
  });

  describe('#propose()', () => {
    let StakeCouncil: Contract;

    beforeEach(async () => {
      await Council.initialize(
        StakeModule.address, // 모듈 주소
        BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
        BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
        BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
        '0', // 제안서 투표 시작 딜레이 0일
        '5', // 제안서 투표 기간 5일
        '10',
      );
      StakeCouncil = StakeModule.attach(Council.address);
      await Token.approve(Council.address, constants.MaxUint256);
      await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
      // await network.provider.send("evm_mine");
    });

    // it('rate test', async () => {
    //   await Token.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
    //   await StakeCouncil.stake(BigNumber.from('100000000000000000000')); // 100개 스테이크
    //   await StakeCouncil.connect(walletTo).stake(BigNumber.from('100000000000000000000')); // 100개 스테이크
    //   const number = await ethers.provider.getBlockNumber();
    //   console.log(await StakeCouncil.getPriorRate(WalletAddress, number - 1));
    //   console.log(await StakeCouncil.getPriorRate(ToAddress, number - 1));
    // });

    it('should be success propose', async () => {
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      expect(
        await Council.propose(Governance.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
      ).to.emit(Council, 'Proposed');
    });

    it('should be revert with not reached quorum', async () => {
      // 다른 계좌의 스테이킹
      await Token.mintTo(ToAddress, BigNumber.from('100000000000000000000')); // 100개 생성
      await StakeCouncil.connect(walletTo).stake(BigNumber.from('100000000000000000000')); // 100개 스테이크

      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      await expect(
        Council.propose(Governance.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
      ).revertedWith('Council/Not Reached Quorum');
    });

    it('should be revert with same proposalid', async () => {
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      expect(
        await Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']),
      ).to.emit(Council, 'Proposed');
      await expect(Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']))
        .reverted;
    });
  });

  describe('#vote()', () => {
    let StakeCouncil: Contract;
    let pid: String;
    let nextLevel: BigNumber;
    let blockNumber: number;

    beforeEach(async () => {
      const getVersion = await Governance.version();
      const getNonce = (await Governance.nonce()).add(1);
      pid = keccak256(
        defaultAbiCoder.encode(
          ['address', 'string', 'address', 'uint128'],
          [Governance.address, getVersion, Council.address, getNonce],
        ),
      );

      await Council.initialize(
        StakeModule.address, // 모듈 주소
        BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
        BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
        BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
        '0', // 제안서 투표 시작 딜레이 0일
        '5', // 제안서 투표 기간 5일
        '0',
      );
      StakeCouncil = StakeModule.attach(Council.address);
      await Token.approve(Council.address, constants.MaxUint256);
      await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      await StakeCouncil.connect(walletTo).stake(BigNumber.from('10000000000000000000')); // 10개 스테이크

      let now = await latestTimestamp();
      nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);
      await Council.propose(Governance.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']);
      blockNumber = await latestBlocknumber();
    });

    it('should be success with vote', async () => {
      await expect(Council.vote(pid, true))
        .to.emit(Council, 'Voted')
        .withArgs(WalletAddress, pid, '10000000000000000000');
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('10000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        false,
        false,
      ]);
    });

    it('should be success with change vote', async () => {
      await expect(Council.vote(pid, true))
        .to.emit(Council, 'Voted')
        .withArgs(WalletAddress, pid, '10000000000000000000');
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('10000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        false,
        false,
      ]);
      await expect(Council.vote(pid, false))
        .to.emit(Council, 'Voted')
        .withArgs(WalletAddress, pid, '10000000000000000000');
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        BigNumber.from('10000000000000000000'),
        false,
        false,
      ]);
    });

    it('should be revert with change vote for same', async () => {
      await expect(Council.vote(pid, true))
        .to.emit(Council, 'Voted')
        .withArgs(WalletAddress, pid, '10000000000000000000');
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('10000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        false,
        false,
      ]);
      await expect(Council.vote(pid, true)).reverted;
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('10000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        false,
        false,
      ]);
    });

    it('should be revert with non-exist pid', async () => {
      await expect(Council.vote('0x00000000000000000000000000000000000000000000000000000000000000f1', true)).reverted;
    });
  });

  describe('#resolve()', () => {
    let StakeCouncil: Contract;
    let pid: String;
    let nextLevel: BigNumber;
    let blockNumber: number;

    beforeEach(async () => {
      const getVersion = await Governance.version();
      const getNonce = (await Governance.nonce()).add(1);
      pid = keccak256(
        defaultAbiCoder.encode(
          ['address', 'string', 'address', 'uint128'],
          [Governance.address, getVersion, Council.address, getNonce],
        ),
      );

      await Council.initialize(
        StakeModule.address, // 모듈 주소
        BigNumber.from('1000'), // proposal 제안 가능 수량 10.00%
        BigNumber.from('7000'), // proposal 성공 기준 수량 70.00%
        BigNumber.from('9500'), // emergency proposal 성공 기준 95.55%
        '0', // 제안서 투표 시작 딜레이 0일
        '5', // 제안서 투표 기간 5일
        '0',
      );
      StakeCouncil = StakeModule.attach(Council.address);
      await Token.approve(Council.address, constants.MaxUint256);
      await Token.connect(walletTo).approve(Council.address, constants.MaxUint256);
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      await StakeCouncil.connect(walletTo).stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      await ethers.provider.send('evm_mine', []);

      let now = await latestTimestamp();
      nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      await Council.propose(Governance.address, [constants.HashZero, constants.HashZero], ['0x00', '0x00']);
      blockNumber = await latestBlocknumber();
    });

    it('should be success with not reached vote', async () => {
      await Council.vote(pid, true);

      // console.log(await StakeCouncil.getPriorPower(constants.AddressZero, blockNumber - 1));
      // console.log(await StakeCouncil.getPriorPower(WalletAddress, blockNumber - 1));
      // console.log(await StakeCouncil.getPriorPower(ToAddress, blockNumber - 1));

      let now = await latestTimestamp();
      const lnextLevel = day.add(now);
      await ethers.provider.send('evm_setNextBlockTimestamp', [lnextLevel.toNumber()]);
      await expect(Council.resolve(pid)).revertedWith('Council/Not Reached Quorum');
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('10000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('10000000000000000000'),
        false, // queued
        false, //leftout
      ]);
    });

    it('should be success with reached vote', async () => {
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      await Council.vote(pid, true);
      await Council.connect(walletTo).vote(pid, true);

      // console.log(await StakeCouncil.getPriorPower(constants.AddressZero, blockNumber - 1));
      // console.log(await StakeCouncil.getPriorPower(WalletAddress, blockNumber - 1));
      // console.log(await StakeCouncil.getPriorPower(ToAddress, blockNumber - 1));

      let now = await latestTimestamp();
      const lnextLevel = day.add(now);
      await ethers.provider.send('evm_setNextBlockTimestamp', [lnextLevel.toNumber()]);

      await expect(Council.resolve(pid)).emit(Council, 'Resolved').withArgs(pid);
      expect(await Council.proposals(pid)).to.deep.equal([
        Governance.address,
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('5').mul('60').add(nextLevel).toNumber(),
        BigNumber.from('0').mul('60').add(nextLevel).toNumber(),
        blockNumber,
        0,
        BigNumber.from('20000000000000000000'),
        BigNumber.from('0'),
        BigNumber.from('20000000000000000000'),
        true,
        false, //leftout
      ]);
    });
  });
});
