import { task, subtask } from 'hardhat/config';
import '@nomiclabs/hardhat-waffle';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-solhint';
import 'hardhat-gas-reporter';
import 'solidity-coverage';
import 'hardhat-deploy';
import '@foundry-rs/hardhat-anvil';

import { resolve } from 'path';
import { config as dotenvConfig } from 'dotenv';
import { HardhatUserConfig } from 'hardhat/config';
import { NetworkUserConfig } from 'hardhat/types';

import fs from 'fs';
import 'hardhat-preprocessor';

interface AnvilOptions {
  url: string;
  accountKeysPath?: string; // Translates to: account_keys_path
  accounts?: object[] | object;
  hostname?: string;
  allowUnlimitedContractSize?: boolean;
  blockTime?: number;
  launch?: boolean; // whether to launch the server at all
  defaultBalanceEther?: number; // Translates to: default_balance_ether
  forkUrl?: string | object;
  forkBlockNumber?: string | number; // Translates to: fork_block_number
  gasLimit?: number;
  gasPrice?: string | number;
  hdPath?: string; // Translates to: hd_path
  mnemonic?: string;
  path?: string; // path to the anvil exec
  locked?: boolean;
  noStorageCaching?: boolean;
  hardfork?: string;
  logger?: {
    log(msg: string): void;
  };
  chainId?: number;
  port?: number;
  totalAccounts?: number; // Translates to: total_accounts
  silent?: boolean;
  vmErrorsOnRPCResponse?: boolean;
  ws?: boolean;
}

function getRemappings() {
  return fs
    .readFileSync('remappings.txt', 'utf8')
    .split('\n')
    .filter(Boolean) // remove empty lines
    .filter(line => !line.match('node_modules'))
    .map(line => line.trim().split('='));
}

const { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } = require('hardhat/builtin-tasks/task-names');
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, __, runSuper) => {
  const paths = await runSuper();

  return paths.filter((p: any) => !p.endsWith('.t.sol'));
});

if (process.env.NODE_ENV === 'production') {
  dotenvConfig({ path: resolve(__dirname, './.env.production') });
} else {
  dotenvConfig({ path: resolve(__dirname, './.env.development') });
}

task('accounts', 'Prints the list of accounts', async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log('address: ' + (await account.getAddress()));
  }
});

const providers = {
  rivet: 1,
  infura: 2,
};

const chainIds = {
  eth: 1,
  ropsten: 3,
  rinkeby: 4,
  goerli: 5,
  kovan: 42,
  optimism: 10,
  'optimism-kovan': 69,
  hardhat: 31337,
};

const mnemonic: string | undefined = process.env.MNEMONIC;
if (!mnemonic) {
  throw new Error('Please set your MNEMONIC in a .env file');
}

const rivetKey: string | undefined = process.env.RIVET_KEY;
if (!rivetKey) {
  throw new Error('Please set your RIVET_KEY in a .env file');
}

function getChainConfig(network: keyof typeof chainIds, mainnet = false): NetworkUserConfig {
  const url: string = 'https://' + rivetKey + '.' + network + '.rpc.rivet.cloud/';
  return {
    accounts: {
      count: 10,
      mnemonic,
      path: mainnet ? "m/44'/60'/0'/0" : "m/44'/1'/0'/0",
    },
    chainId: chainIds[network],
    deploy: ['deploy_l1'],
    url,
  };
}

function getOptimismConfig(network: keyof typeof chainIds, mainnet = false): NetworkUserConfig {
  const url: string = `https://${mainnet ? `mainnet` : `kovan`}.optimism.io/`;
  return {
    accounts: {
      count: 10,
      mnemonic,
      path: mainnet ? "m/44'/60'/0'/0" : "m/44'/1'/0'/0",
    },
    chainId: chainIds[network],
    deploy: ['deploy'],
    url,
  };
}

const config: HardhatUserConfig = {
  defaultNetwork: 'anvil',

  namedAccounts: {
    deployer: 0,
  },

  gasReporter: {
    currency: 'USD',
    enabled: true,
    excludeContracts: [],
    src: './contracts',
  },

  networks: {
    localhost: {
      url: 'http://localhost:8545',
    },
    hardhat: {
      accounts: {
        mnemonic,
        path: "m/44'/1'/0'/0",
      },
    },
    anvil: {
      url: 'http://127.0.0.1:8545/',
      accounts: {
        mnemonic,
        path: "m/44'/60'/0'/0",
      },
    },
    coverage: {
      url: 'http://localhost:8555',
    },
    goerli: getChainConfig('goerli'),
    rinkeby: getChainConfig('rinkeby'),
    ropsten: getChainConfig('ropsten'),
    mainnet: getChainConfig('eth', true),
    'optimism-kovan': getOptimismConfig('optimism-kovan'),
    optimism: getOptimismConfig('optimism', true),
  },

  solidity: {
    compilers: [
      {
        version: '0.8.17',
        settings: {
          viaIR: true,
          optimizer: {
            enabled: true,
            runs: 42069,
            details: {
              yul: true,
            },
          },
        },
      },
    ],
  },

  external: {
    contracts: [
      {
        artifacts: 'node_modules/@beandao/contracts/build/contracts',
      },
      {
        artifacts: 'node_modules/@beandao/contracts/build/contracts',
      },
    ],
    deployments: {},
  },

  paths: {
    deploy: 'deploy',
    deployments: 'deployments',
    sources: './contracts',
    tests: './test',
    cache: './hh-cache',
    artifacts: './artifacts',
  },

  // This fully resolves paths for imports in the ./lib directory for Hardhat
  preprocess: {
    eachLine: hre => ({
      transform: (line: string) => {
        if (line.match(/^\s*import /i)) {
          getRemappings().forEach(([find, replace]) => {
            if (line.match(find)) {
              line = line.replace(find, replace);
            }
          });
        }
        return line;
      },
    }),
  },

  etherscan: {
    apiKey: '',
  },

  mocha: {
    timeout: 0,
  },
};

export default config;
