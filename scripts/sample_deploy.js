async function main() {
  const StandardTokenTemplate = await ethers.getContractFactory('StandardToken');
  const StandardToken = await StandardTokenTemplate.deploy();
  await StandardToken.deployed();
  await StandardToken.initialize('1', 'Template', 'TEMP', 18);
  console.log('StandardToken deployed to:', StandardToken.address);
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
