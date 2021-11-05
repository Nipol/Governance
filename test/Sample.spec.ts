import { expect } from 'chai';
import { ethers } from 'hardhat';
import { Contract, Signer } from 'ethers';

describe('Sample Test', () => {
    let Sample: Contract;

    let wallet: Signer;
    let walletTo: Signer;
    let Dummy: Signer;

    beforeEach(async () => {
      const accounts = await ethers.getSigners();
      [wallet, walletTo, Dummy] = accounts;

      const SampleDeployer = await ethers.getContractFactory('contracts/Sample.sol:Sample', wallet);
      Sample = await SampleDeployer.deploy("0.8.7 Sample");
    });

    describe('name', () => {
      it('should be success', async () => {
        expect(await Sample.name()).to.be.equal("0.8.7 Sample");
      });
    });
});
