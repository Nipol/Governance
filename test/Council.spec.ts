import { expect } from 'chai';
import { ethers } from 'hardhat';
import { BigNumber, constants, Contract, Signer } from 'ethers';

describe('Council', () => {
  let Governance: Contract;
  let GovernanceMock: Contract;
  let Council: Contract;
  let StakeModule: Contract;
  let Token: Contract;

  let wallet: Signer;
  let walletTo: Signer;
  let Dummy: Signer;

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    [wallet, walletTo, Dummy] = accounts;

    const GovernanceDeployer = await ethers.getContractFactory('contracts/Governance.sol:Governance', wallet);
    const GovernanceMockDeployer = await ethers.getContractFactory(
      'contracts/mocks/GovernanceMock.sol:GovernanceMock',
      wallet,
    );
    const CouncilDeployer = await ethers.getContractFactory('contracts/Council.sol:Council', wallet);
    const StakeModuleDeployer = await ethers.getContractFactory(
      'contracts/VoteModule/StakeModule.sol:StakeModule',
      wallet,
    );
    const TokenDeployer = await ethers.getContractFactory('contracts/mocks/ERC20.sol:TokenMock', wallet);
    Governance = await GovernanceDeployer.deploy();
    GovernanceMock = await GovernanceMockDeployer.deploy();
    Token = await TokenDeployer.deploy('bean', 'bean', 18);
    await Token.mint(BigNumber.from('100000000000000000000')); // 100개 생성
    StakeModule = await StakeModuleDeployer.deploy(Token.address);
    Council = await CouncilDeployer.deploy();
    // 초기화 시작
    const day = BigNumber.from('60').mul('60').mul('24');
    await Governance.initialize('bean the DAO', Council.address, day);
  });

  describe('#propose()', () => {
    let StakeCouncil: Contract;

    beforeEach(async () => {
      await Council.initialize(
        StakeModule.address, // 모듈 주소
        BigNumber.from('10000000000000000000'), // proposal 가능 수량 10개
        BigNumber.from('50000000000000000000'), // proposal 성공 기준 수량 50개
        '0',
        '60',
        '10',
      );
      StakeCouncil = StakeModule.attach(Council.address);
      await Token.approve(Council.address, constants.MaxUint256);
      // await network.provider.send("evm_mine");
    });

    it('should be success propose', async () => {
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      expect(
        await Council.propose(
          Governance.address,
          [constants.HashZero, constants.HashZero],
          ['0', '0'],
          ['0x00', '0x00'],
        ),
      ).to.emit(Council, 'Proposed');
    });

    it('should be revert with not reached quorum', async () => {
      await StakeCouncil.stake(BigNumber.from('9000000000000000000')); // 10개 스테이크
      await expect(
        Council.propose(Governance.address, [constants.HashZero, constants.HashZero], ['0', '0'], ['0x00', '0x00']),
      ).revertedWith('Council/Not Reached Quorum');
    });

    it('should be revert with same proposalid', async () => {
      await StakeCouncil.stake(BigNumber.from('10000000000000000000')); // 10개 스테이크
      expect(
        await Council.propose(
          GovernanceMock.address,
          [constants.HashZero, constants.HashZero],
          ['0', '0'],
          ['0x00', '0x00'],
        ),
      ).to.emit(Council, 'Proposed');
      await expect(
        Council.propose(GovernanceMock.address, [constants.HashZero, constants.HashZero], ['0', '0'], ['0x00', '0x00']),
      ).reverted;
    });
  });
});
