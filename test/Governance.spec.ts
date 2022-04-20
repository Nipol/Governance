import { expect } from 'chai';
import hre, { ethers } from 'hardhat';
import { BigNumber, constants, Contract, Signer, Wallet } from 'ethers';
import {
  defaultAbiCoder,
  Interface,
  keccak256,
  concat,
  hexZeroPad,
  hexlify,
  joinSignature,
  SigningKey,
  splitSignature,
  arrayify,
  hashMessage,
  solidityPack,
  solidityKeccak256,
} from 'ethers/lib/utils';

const day = BigNumber.from('60').mul('60').mul('24');
export async function latestTimestamp(): Promise<number> {
  return (await ethers.provider.getBlock('latest')).timestamp;
}

const computeMagicHash = (spells: Uint8Array[] | string[], elements: string[]): string => {
  if (typeof spells[0] === 'string') {
    return keccak256(
      defaultAbiCoder.encode(
        ['bytes32', 'bytes32'],
        [solidityKeccak256(['bytes32[]'], [spells]), keccak256(defaultAbiCoder.encode(['bytes[]'], [elements]))],
      ),
    );
  } else {
    const lspells = spells.map(value => {
      return '0x' + Buffer.from(value).toString('hex');
    });

    return keccak256(
      defaultAbiCoder.encode(
        ['bytes32', 'bytes32'],
        [solidityKeccak256(['bytes32[]'], [lspells]), keccak256(defaultAbiCoder.encode(['bytes[]'], [elements]))],
      ),
    );
  }
};

enum GovernanceErrors {
  FROM_NOT_COUNCIL = 'Governance__FromNotCouncil',
  FROM_NOT_GOVERNANCE = 'Governance__FromNotGovernance',
  NOT_PROPOSED = 'Governance__NotProposed',
  NOT_COUNCIL_CONTRACT = 'Governance__NotCouncilContract',
  SCHEDULER_NOT_QUEUED = 'Scheduler__NotQueued',
  SCHEDULER_DELAY_IS_NOT_RANGE = 'Scheduler__DelayIsNotRange',
  INVALID_ADDRESS = 'Governance__InvalidAddress',
  INVALID_MAGICHASH = 'Governance__InvalidMagicHash',
  INVALID_SIGNATURE = 'Governance__InvalidSignature',
  INVALID_SIGNATURE_S = 'Governance__InvalidSignature_S',
  INVALID_SIGNATURE_V = 'Governance__InvalidSignature_V',
}

describe('Governance', () => {
  let Governance: Contract;
  let Token: Contract;

  let wallet: Signer;
  let To: Signer;
  let Dummy: Signer;

  let WalletAddress: string;
  let ToAddress: string;

  const initialToken = BigNumber.from('100000000000000000000');

  beforeEach(async () => {
    const accounts = await ethers.getSigners();
    [wallet, To, Dummy] = accounts;
    WalletAddress = await wallet.getAddress();
    ToAddress = await To.getAddress();

    const govFactory = await ethers.getContractFactory('contracts/Governance.sol:Governance', wallet);

    Governance = await govFactory.deploy();

    const deployer = await (
      await ethers.getContractFactory('contracts/mocks/Deployer.sol:Deployer', wallet)
    ).deploy(Governance.address);

    const councilAddr = await deployer.calculate();
    await deployer.deployIncrement();

    Governance = govFactory.attach(councilAddr);

    Token = await (
      await ethers.getContractFactory('contracts/mocks/ERC20.sol:StandardToken', wallet)
    ).deploy('bean', 'bean', 18);
    await Token.mintTo(Governance.address, initialToken); // 거버넌스에 토큰 100개 생성
  });

  describe('#initialize()', () => {
    beforeEach(async () => {
      // await network.provider.send("evm_mine");
    });

    it('should be success initial council and delay with day', async () => {
      await expect(Governance.initialize('bean the DAO', WalletAddress, day))
        .to.emit(Governance, 'Delayed')
        .withArgs(day);
      expect(await Governance.name()).equal('bean the DAO');
      expect(await Governance.council()).equal(WalletAddress);
    });

    it('should be revert with zero addr council', async () => {
      await expect(Governance.initialize('bean the DAO', constants.AddressZero, day)).reverted;
      expect(await Governance.name()).equal('');
      expect(await Governance.council()).equal(constants.AddressZero);
    });
  });

  describe('#propose()', () => {
    beforeEach(async () => {
      await expect(Governance.initialize('bean the DAO', WalletAddress, day))
        .to.emit(Governance, 'Delayed')
        .withArgs(day);
    });

    it('should be success propose', async () => {
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      const magichash = keccak256(
        defaultAbiCoder.encode(
          ['bytes32', 'bytes32'],
          [solidityKeccak256(['bytes32[]'], [[]]), keccak256(defaultAbiCoder.encode(['bytes[]'], [[]]))],
        ),
      ).slice(0, 34);

      const expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells: [], elements: [] };
      await expect(Governance.propose(param))
        .to.emit(Governance, 'Proposed')
        .withArgs(expectedId, version, nonce, WalletAddress, WalletAddress, [], [], magichash);
      expect(await Governance.nonce()).equal(nonce);
    });

    it('should be revert call from not council', async () => {
      const getNonce = await Governance.nonce();
      const param = { proposer: WalletAddress, spells: [], elements: [] };
      await expect(Governance.connect(To).propose(param)).revertedWith(GovernanceErrors.FROM_NOT_COUNCIL);
      expect(await Governance.nonce()).equal(getNonce);
    });
  });

  describe('#approve()', () => {
    let expectedId: string;

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      const magichash = keccak256(
        defaultAbiCoder.encode(
          ['bytes32', 'bytes32'],
          [solidityKeccak256(['bytes32[]'], [[]]), keccak256(defaultAbiCoder.encode(['bytes[]'], [[]]))],
        ),
      ).slice(0, 34);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );
      const param = { proposer: WalletAddress, spells: [], elements: [] };
      await Governance.propose(param);
    });

    it('should be success standby', async () => {
      await expect(Governance.approve(expectedId))
        .to.emit(Governance, '0x6fb7fd1eda743aa3eb32c69f3b8cf14a5aeadf26db51057a7c5c78ba10eac8a4')
        .withArgs(expectedId);
    });

    it('should be reverted with non exist proposal id', async () => {
      await expect(Governance.approve(constants.HashZero)).revertedWith(GovernanceErrors.NOT_PROPOSED);
    });
  });

  describe('#drop()', () => {
    let expectedId: string;

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      const magichash = keccak256(
        defaultAbiCoder.encode(
          ['bytes32', 'bytes32'],
          [solidityKeccak256(['bytes32[]'], [[]]), keccak256(defaultAbiCoder.encode(['bytes[]'], [[]]))],
        ),
      ).slice(0, 34);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );
      const param = { proposer: WalletAddress, spells: [], elements: [] };
      await Governance.propose(param);
    });

    it('should be success drop', async () => {
      await expect(Governance.drop(expectedId)).to.emit(Governance, 'Dropped').withArgs(expectedId);
    });

    it('should be Reverted with non exist proposal id', async () => {
      await expect(Governance.drop(constants.HashZero)).revertedWith(GovernanceErrors.NOT_PROPOSED);
    });
  });

  describe('#execute()', () => {
    let magichash: string;
    let expectedId: string;
    let spells: Uint8Array[];
    let elements: string[];

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
      const ABI = ['function balanceOf(address target)', 'function transfer(address to,uint256 value)'];
      const interfaces = new Interface(ABI);
      const balanceOfsig = interfaces.getSighash('balanceOf');
      const transferSig = interfaces.getSighash('transfer');
      // 거버넌스가 가지고 있는 전체 토큰 수량을 쿼리 한 후
      // 해당 수량만큼 다른 주소로 전송함.
      spells = [
        concat([
          balanceOfsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0x00',
          Token.address, // address
        ]),
        concat([
          transferSig, // function selector
          '0x40', // flag
          '0x01', // value position from elements array
          '0x00',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Token.address, // address
        ]),
      ];

      elements = [
        '0x000000000000000000000000' + Governance.address.slice(2), // for balanceof
        '0x000000000000000000000000' + ToAddress.slice(2), // transfer
      ];

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      magichash = computeMagicHash(spells, elements).slice(0, 34);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );
      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);
    });

    it('should be success execute', async () => {
      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      await expect(Governance.execute(expectedId, spells, elements))
        .to.emit(Token, 'Transfer')
        .withArgs(Governance.address, ToAddress, initialToken);
      expect(await Token.balanceOf(ToAddress)).to.equal(initialToken);
      expect(await Governance.proposals(expectedId)).to.deep.equal([BigNumber.from('0x01'), magichash, 4, 0]);
    });

    it('should be success after grace period', async () => {
      let now = await latestTimestamp();
      const nextLevel = day.mul('9').add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);
      await expect(Governance.execute(expectedId, spells, elements)).to.emit(Governance, 'Staled').withArgs(expectedId);
      expect(await Token.balanceOf(Governance.address)).to.equal(initialToken);
      expect(await Governance.proposals(expectedId)).to.deep.equal([BigNumber.from('0x01'), magichash, 3, 0]);
    });

    it('should be revert with non exist Proposal Id', async () => {
      await expect(Governance.execute(constants.HashZero, spells, elements)).revertedWith(
        GovernanceErrors.SCHEDULER_NOT_QUEUED,
      );
    });

    it('should be revert with already executed Proposal Id', async () => {
      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      await expect(Governance.execute(expectedId, spells, elements))
        .to.emit(Token, 'Transfer')
        .withArgs(Governance.address, ToAddress, initialToken);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(
        GovernanceErrors.SCHEDULER_NOT_QUEUED,
      );
    });
  });

  describe('#changeCouncil()', () => {
    let expectedId: string;

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success change council', async () => {
      const Council = await (
        await ethers.getContractFactory('contracts/mocks/CouncilMock.sol:CouncilMock', wallet)
      ).deploy();
      const ABI = ['function changeCouncil(address councilAddr) external'];
      const interfaces = new Interface(ABI);
      const changeCouncilsig = interfaces.getSighash('changeCouncil');

      const spells = [
        concat([
          changeCouncilsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + Council.address.slice(2), // for changeCouncil
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );
      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.council()).to.equal(WalletAddress);
      await expect(Governance.execute(expectedId, spells, elements))
        .to.emit(Governance, 'Executed')
        .withArgs(expectedId);
      expect(await Governance.council()).to.equal(Council.address);
    });

    it('should be reverted with non council contract', async () => {
      const ABI = ['function changeCouncil(address councilAddr) external'];
      const interfaces = new Interface(ABI);
      const changeCouncilsig = interfaces.getSighash('changeCouncil');

      const spells = [
        concat([
          changeCouncilsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + Token.address.slice(2), // for changeCouncil
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );
      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.council()).to.equal(WalletAddress);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(
        GovernanceErrors.NOT_COUNCIL_CONTRACT,
      );
    });

    it('should be reverted with self delegate call', async () => {
      const ABI = ['function changeCouncil(address councilAddr) external'];
      const interfaces = new Interface(ABI);
      const changeCouncilsig = interfaces.getSighash('changeCouncil');
      const spells = [
        concat([
          changeCouncilsig, // function selector
          '0x00', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + Token.address.slice(2), // for changeCouncil
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.council()).to.equal(WalletAddress);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(GovernanceErrors.FROM_NOT_GOVERNANCE);
    });

    it('should be revert from non governance address', async () => {
      await expect(Governance.changeCouncil(Token.address)).revertedWith(GovernanceErrors.FROM_NOT_GOVERNANCE);
    });
  });

  describe('#changeDelay()', () => {
    let expectedId: string;

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success change delay', async () => {
      const ABI = ['function changeDelay(uint32 executeDelay) external'];
      const interfaces = new Interface(ABI);
      const changeDelaysig = interfaces.getSighash('changeDelay');

      const spells = [
        concat([
          changeDelaysig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];
      const elements = [
        hexZeroPad(hexlify(day.mul('2')), 32), // for changeCouncil
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await expect(Governance.execute(expectedId, spells, elements))
        .to.emit(Governance, 'Executed')
        .withArgs(expectedId);
      expect(await Governance.delay()).to.equal(day.mul('2'));
    });

    it('should be reverted with out of delay range', async () => {
      const ABI = ['function changeDelay(uint32 executeDelay) external'];
      const interfaces = new Interface(ABI);
      const changeDelaysig = interfaces.getSighash('changeDelay');

      const spells = [
        concat([
          changeDelaysig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];
      const elements = [
        hexZeroPad(hexlify(day.mul('31')), 32), // for changeCouncil
      ];
      const magichash = computeMagicHash(spells, elements).slice(0, 34);
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(
        GovernanceErrors.SCHEDULER_DELAY_IS_NOT_RANGE,
      );
    });

    it('should be reverted with self delegate call', async () => {
      const ABI = ['function changeDelay(uint32 executeDelay) external'];
      const interfaces = new Interface(ABI);
      const changeDelaysig = interfaces.getSighash('changeDelay');

      const spells = [
        concat([
          changeDelaysig, // function selector
          '0x00', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];
      const elements = [
        hexZeroPad(hexlify(day.mul('2')), 32), // for changeCouncil
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(GovernanceErrors.FROM_NOT_GOVERNANCE);
    });

    it('should be revert from non governance address', async () => {
      await expect(Governance.changeDelay(day.mul('2'))).revertedWith(GovernanceErrors.FROM_NOT_GOVERNANCE);
    });
  });

  describe('#emergencyExecute()', () => {
    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success execute', async () => {
      const ABI = ['function balanceOf(address target)', 'function transfer(address to,uint256 value)'];
      const interfaces = new Interface(ABI);
      const balanceOfsig = interfaces.getSighash('balanceOf');
      const transferSig = interfaces.getSighash('transfer');

      // 거버넌스가 가지고 있는 전체 토큰 수량을 쿼리 한 후
      // 해당 수량만큼 다른 주소로 전송함.
      const spells = [
        concat([
          balanceOfsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0x00',
          Token.address, // address
        ]),
        concat([
          transferSig, // function selector
          '0x40', // flag
          '0x01', // value position from elements array
          '0x00',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Token.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + Governance.address.slice(2), // for balanceof
        '0x000000000000000000000000' + ToAddress.slice(2), // transfer
      ];

      await expect(Governance.emergencyExecute(spells, elements))
        .to.emit(Token, 'Transfer')
        .withArgs(Governance.address, ToAddress, initialToken);
      expect(await Governance.nonce()).to.equal('1');
    });

    it('should be revert with from non council contract', async () => {
      await expect(Governance.connect(To).emergencyExecute([], [])).revertedWith(GovernanceErrors.FROM_NOT_COUNCIL);
      expect(await Governance.nonce()).to.equal('0');
    });
  });

  describe('#emergencyCouncil()', () => {
    let expectedId: string;

    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success change Council', async () => {
      const ABI = ['function emergencyCouncil(address councilorAddr) external'];
      const interfaces = new Interface(ABI);
      const emergencyCouncilsig = interfaces.getSighash('emergencyCouncil');

      // 거버넌스가 가지고 있는 전체 토큰 수량을 쿼리 한 후
      // 해당 수량만큼 다른 주소로 전송함.
      const spells = [
        concat([
          emergencyCouncilsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + ToAddress.slice(2), // transfer
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await Governance.execute(expectedId, spells, elements);
      expect(await Governance.council()).to.equal(ToAddress);
    });

    it('should be revert with already registerd council address', async () => {
      const ABI = ['function emergencyCouncil(address councilorAddr) external'];
      const interfaces = new Interface(ABI);
      const emergencyCouncilsig = interfaces.getSighash('emergencyCouncil');

      // 거버넌스가 가지고 있는 전체 토큰 수량을 쿼리 한 후
      // 해당 수량만큼 다른 주소로 전송함.
      const spells = [
        concat([
          emergencyCouncilsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + WalletAddress.slice(2), // transfer
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);
      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(GovernanceErrors.INVALID_ADDRESS);
      expect(await Governance.council()).to.equal(WalletAddress);
    });

    it('should be revert with governance address', async () => {
      const ABI = ['function emergencyCouncil(address councilorAddr) external'];
      const interfaces = new Interface(ABI);
      const emergencyCouncilsig = interfaces.getSighash('emergencyCouncil');

      // 거버넌스가 가지고 있는 전체 토큰 수량을 쿼리 한 후
      // 해당 수량만큼 다른 주소로 전송함.
      const spells = [
        concat([
          emergencyCouncilsig, // function selector
          '0x40', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const elements = [
        '0x000000000000000000000000' + Governance.address.slice(2), // transfer
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      expect(await Governance.delay()).to.equal(day);
      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(GovernanceErrors.INVALID_ADDRESS);
      expect(await Governance.council()).to.equal(WalletAddress);
    });

    it('should be reverted with self delegate call', async () => {
      const ABI = ['function changeCouncil(address councilAddr) external'];
      const interfaces = new Interface(ABI);
      const changeCouncilsig = interfaces.getSighash('changeCouncil');
      const elements = [
        '0x000000000000000000000000' + ToAddress.slice(2), // for changeCouncil
      ];

      const spells = [
        concat([
          changeCouncilsig, // function selector
          '0x00', // flag return value not tuple
          '0x00', // value position from elements array
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          '0xFF',
          Governance.address, // address
        ]),
      ];

      const magichash = computeMagicHash(spells, elements).slice(0, 34);

      const version = await Governance.version();
      const nonce = (await Governance.nonce()).add(1);
      expectedId = solidityKeccak256(
        ['address', 'string', 'uint96', 'address', 'address', 'bytes16'],
        [Governance.address, version, nonce, WalletAddress, WalletAddress, magichash],
      );

      const param = { proposer: WalletAddress, spells, elements };
      await Governance.propose(param);
      await Governance.approve(expectedId);

      let now = await latestTimestamp();
      const nextLevel = day.add(now).add('1');
      await ethers.provider.send('evm_setNextBlockTimestamp', [nextLevel.toNumber()]);

      await expect(Governance.execute(expectedId, spells, elements)).revertedWith(GovernanceErrors.FROM_NOT_GOVERNANCE);
      expect(await Governance.council()).to.equal(WalletAddress);
    });
  });

  describe('#isValidSignature()', () => {
    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success valid signature', async () => {
      const hash = keccak256(hexlify('0x321321'));
      const sig = joinSignature(
        new SigningKey('0x7c299dda7c704f9d474b6ca5d7fee0b490c8decca493b5764541fe5ec6b65114').signDigest(hash),
      );

      expect(await Governance.isValidSignature(hash, sig)).to.equal('0x1626ba7e');
    });

    it('should be success invalid hash', async () => {
      const hash = hashMessage(hexlify('0x321321'));
      const sig = joinSignature(
        new SigningKey('0x7c299dda7c704f9d474b6ca5d7fee0b490c8decca493b5764541fe5ec6b65114').signDigest(hash),
      );
      expect(await Governance.isValidSignature(hexZeroPad(hexlify('0x321321'), 32), sig)).to.equal('0xffffffff');
    });

    it('should be revert invalid signature s', async () => {
      const hash = keccak256(hexlify('0x321321'));
      const splited = new SigningKey('0x7c299dda7c704f9d474b6ca5d7fee0b490c8decca493b5764541fe5ec6b65114').signDigest(
        hash,
      );

      const sig = `${
        splited.r
      }${'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0'.toLowerCase()}${hexlify(splited.v).slice(
        2,
      )}`;
      await expect(Governance.isValidSignature(hash, sig)).revertedWith(GovernanceErrors.INVALID_SIGNATURE_S);
    });

    it('should be revert invalid signature v', async () => {
      const hash = keccak256(hexlify('0x321321'));
      const splited = new SigningKey('0x7c299dda7c704f9d474b6ca5d7fee0b490c8decca493b5764541fe5ec6b65114').signDigest(
        hash,
      );

      const sig = `${splited.r}${splited.s.slice(2)}${hexlify(30).slice(2)}`;
      await expect(Governance.isValidSignature(hash, sig)).revertedWith(GovernanceErrors.INVALID_SIGNATURE_V);
    });

    it('should be revert invalid signature length', async () => {
      const hash = keccak256(hexlify('0x321321'));
      const splited = new SigningKey('0x7c299dda7c704f9d474b6ca5d7fee0b490c8decca493b5764541fe5ec6b65114').signDigest(
        hash,
      );

      const sig = `${splited.r}${splited.s.slice(4)}`;
      await expect(Governance.isValidSignature(hash, sig)).revertedWith(GovernanceErrors.INVALID_SIGNATURE);
    });
  });

  describe('#onERC721Received()', () => {
    beforeEach(async () => {
      await Governance.initialize('bean the DAO', WalletAddress, day);
    });

    it('should be success receive', async () => {
      const NFT = await (
        await ethers.getContractFactory('contracts/mocks/ERC721.sol:ERC721Mock', wallet)
      ).deploy('Sample', 'SMP');

      await NFT.mint('0');
      await NFT.setApprovalForAll(ToAddress, true);
      expect(await NFT.isApprovedForAll(WalletAddress, ToAddress)).to.equal(true);
      await NFT.connect(To)['safeTransferFrom(address,address,uint256)'](WalletAddress, Governance.address, '0');
      expect(await NFT.ownerOf('0')).to.equal(Governance.address);
      expect(await NFT.isApprovedForAll(Governance.address, ToAddress)).to.equal(false);
    });
  });
});
