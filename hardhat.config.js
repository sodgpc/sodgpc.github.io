// Production compiler settings. This public project only compiles source code.
module.exports = {
  solidity: {
    version: '0.8.21',
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 100 },
      evmVersion: 'paris'
    }
  }
};
