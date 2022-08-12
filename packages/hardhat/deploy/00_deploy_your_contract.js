// deploy/00_deploy_your_contract.js

const { ethers } = require("hardhat");

const localChainId = "31337";

// const sleep = (ms) =>
//   new Promise((r) =>
//     setTimeout(() => {
//       console.log(`waited for ${(ms / 1000).toFixed(3)} seconds`);
//       r();
//     }, ms)
//   );

module.exports = async ({ getNamedAccounts, deployments, getChainId }) => {
    const { deploy } = deployments;
    const { deployer, treasury } = await getNamedAccounts();
    const chainId = await getChainId();

    await deploy("TestToken", {
        from: deployer,
        log: true,
        waitConfirmations: 5,
    });

    const TestToken = await ethers.getContract("TestToken", deployer);
    await TestToken.give1000To(deployer);

    await deploy("HumaConfig", {
        from: deployer,
        log: true,
        args: [deployer],
        waitConfirmations: 5,
    });

    const HumaConfig = await ethers.getContract("HumaConfig", deployer);
    await HumaConfig.setLiquidityAsset(TestToken.address, true);

    await deploy("PoolLockerFactory", {
        from: deployer,
        log: true,
        waitConfirmations: 5,
    });

    const PoolLockerFactory = await ethers.getContract(
        "PoolLockerFactory",
        deployer
    );

    // await deploy("HumaInvoiceFactoring", {
    //     from: deployer,
    //     log: true,
    //     args: [
    //         TestToken.address,
    //         HumaConfig.address,
    //     ],
    //     waitConfirmations: 5,
    // });
    // const poolAddr = await ethers.getContract("HumaInvoiceFactoring", deployer);

    // const invoicePool = await ethers.getContractAt(
    //     "HumaInvoiceFactoring",
    //     poolAddr
    // );
    //await invoicePool.enablePool();
    // await invoicePool.addCreditApprover(
    //     process.env.INITIAL_HUMA_CREDIT_APPROVER
    // );
    // const maxBorrowAmt = 1000000000000000000000000;
    // await invoicePool.setMinMaxBorrowAmt(
    //     1,
    //     maxBorrowAmt.toLocaleString("fullwide", { useGrouping: false })
    // );

    // await deploy("InvoiceNFT", {
    //     from: deployer,
    //     log: true,
    //     waitConfirmations: 5,
    // });

    // await TestToken.approve(invoicePool.address, 1000);
    // await invoicePool.deposit(1000);

    // Getting a previously deployed contract
    // const TestToken = await ethers.getContract("TestToken", deployer);
    /*  await YourContract.setPurpose("Hello");
  
    To take ownership of yourContract using the ownable library uncomment next line and add the 
    address you want to be the owner. 
    // await yourContract.transferOwnership(YOUR_ADDRESS_HERE);

    //const yourContract = await ethers.getContractAt('YourContract', "0xaAC799eC2d00C013f1F11c37E654e59B0429DF6A") //<-- if you want to instantiate a version of a contract at a specific address!
  */

    /*
  //If you want to send value to an address from the deployer
  const deployerWallet = ethers.provider.getSigner()
  await deployerWallet.sendTransaction({
    to: "0x34aA3F359A9D614239015126635CE7732c18fDF3",
    value: ethers.utils.parseEther("0.001")
  })
  */

    /*
  //If you want to send some ETH to a contract on deploy (make your constructor payable!)
  const yourContract = await deploy("YourContract", [], {
  value: ethers.utils.parseEther("0.05")
  });
  */

    /*
  //If you want to link a library into your contract:
  // reference: https://github.com/austintgriffith/scaffold-eth/blob/using-libraries-example/packages/hardhat/scripts/deploy.js#L19
  // const yourContract = await deploy("YourContract", [], {}, {
  //  LibraryName: **LibraryAddress**
  // });
  */

    // Verify from the command line by running `yarn verify`

    // You can also Verify your contracts with Etherscan here...
    // You don't want to verify on localhost
    // try {
    //   if (chainId !== localChainId) {
    //     await run("verify:verify", {
    //       address: YourContract.address,
    //       contract: "contracts/YourContract.sol:YourContract",
    //       constructorArguments: [],
    //     });
    //   }
    // } catch (error) {
    //   console.error(error);
    // }
};
module.exports.tags = ["YourContract"];
