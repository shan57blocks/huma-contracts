//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import "./interfaces/IPoolLocker.sol";
import "./interfaces/IPool.sol";
import "./PoolLocker.sol";
import "./HDT/HDT.sol";
import "./HumaConfig.sol";
import "./PoolLocker.sol";
import "./ReputationTrackerFactory.sol";
import "./ReputationTracker.sol";
import "./interfaces/IReputationTracker.sol";

abstract contract BasePool is IPool, HDT, Ownable {
    using SafeERC20 for IERC20;
    using ERC165Checker for address;

    uint256 constant POWER18 = 10**18;

    // HumaConfig. Removed immutable since Solidity disallow reference it in the constructor,
    // but we need to retrieve the poolDefaultGracePeriod in the constructor.
    address internal humaConfig;

    // Liquidity holder proxy contract for this pool
    address public poolLocker;

    // Tracks the amount of liquidity in poolTokens provided to this pool by an address
    mapping(address => LenderInfo) internal lenderInfo;

    // The ERC20 token this pool manages
    IERC20 public immutable poolToken;
    uint256 public immutable poolTokenDecimals;

    // The max liquidity allowed for the pool.
    uint256 internal liquidityCap;

    // the min amount each loan/credit.
    uint256 internal minBorrowAmt;

    // The maximum amount of poolTokens that this pool allows in a single loan
    uint256 maxBorrowAmt;

    // The interest rate this pool charges for loans
    uint256 interestRateBasis;

    // The collateral basis percentage required from lenders
    uint256 collateralRequired;

    // Platform fee, charged when a loan is originated
    uint256 platform_fee_flat;
    uint256 platform_fee_bps;
    // Late fee, charged when the borrow is late for a pyament.
    uint256 late_fee_flat;
    uint256 late_fee_bps;
    // Early payoff fee, charged when the borrow pays off prematurely
    uint256 early_payoff_fee_flat;
    uint256 early_payoff_fee_bps;

    PoolStatus public status = PoolStatus.Off;

    // List of credit approvers who can approve credit requests.
    mapping(address => bool) public creditApprovers;

    // How long after the last deposit that a lender needs to wait
    // before they can withdraw their capital
    uint256 public withdrawalLockoutPeriod = 2630000;

    uint256 public poolDefaultGracePeriod;

    // reputationTrackerFactory
    address public reputationTrackerFactory;

    address public reputationTrackerContractAddress;

    // todo (by RL) Need to use uint32 and uint48 for diff fields to take advantage of packing
    struct LenderInfo {
        uint256 amount;
        uint256 weightedDepositDate; // weighted average deposit date
        uint256 mostRecentLoanTimestamp;
    }

    enum PoolStatus {
        Off,
        On
    }

    event LiquidityDeposited(address by, uint256 principal);
    event LiquidityWithdrawn(address by, uint256 principal, uint256 netAmt);
    event PoolDeployed(address _poolAddress);

    constructor(
        address _poolToken,
        address _humaConfig,
        address _reputationTrackerFactory
    ) HDT("Huma", "Huma", _poolToken) {
        poolToken = IERC20(_poolToken);
        poolTokenDecimals = ERC20(_poolToken).decimals();
        humaConfig = _humaConfig;
        reputationTrackerFactory = _reputationTrackerFactory;
        poolDefaultGracePeriod = HumaConfig(humaConfig)
            .protocolDefaultGracePeriod();
        reputationTrackerContractAddress = ReputationTrackerFactory(
            reputationTrackerFactory
        ).deployReputationTracker("Huma Pool", "HumaRTT");

        emit PoolDeployed(address(this));
    }

    modifier onlyHumaMasterAdmin() {
        require(
            msg.sender == HumaConfig(humaConfig).owner(),
            "BasePool:PERMISSION_DENIED_NOT_MASTER_ADMIN"
        );
        _;
    }

    //********************************************/
    //               LP Functions                //
    //********************************************/

    /**
     * @notice LP deposits to the pool to earn interest, and share losses
     * @param amount the number of `poolToken` to be deposited
     */
    function makeInitialDeposit(uint256 amount) external virtual override {
        return _deposit(msg.sender, amount);
    }

    function deposit(uint256 amount) external virtual override {
        poolOn();
        // todo (by RL) Need to check if the pool is open to msg.sender to deposit
        // todo (by RL) Need to add maximal pool size support and check if it has reached the size
        return _deposit(msg.sender, amount);
    }

    function _deposit(address lender, uint256 amount) internal {
        uint256 amtInPower18 = _toPower18(amount);

        // Update weighted deposit date:
        // prevDate + (now - prevDate) * (amount / (balance + amount))
        // NOTE: prevDate = 0 implies balance = 0, and equation reduces to now
        uint256 prevDate = lenderInfo[lender].weightedDepositDate;
        uint256 balance = lenderInfo[lender].amount;

        uint256 newDate = (balance + amount) > 0
            ? prevDate +
                (((block.timestamp - prevDate) * amount) / (balance + amount))
            : prevDate;

        lenderInfo[lender].weightedDepositDate = newDate;
        lenderInfo[lender].amount += amount;
        lenderInfo[lender].mostRecentLoanTimestamp = block.timestamp;

        poolToken.safeTransferFrom(lender, poolLocker, amount);

        // Mint HDT for the LP to claim future income and losses
        _mint(lender, amtInPower18);

        emit LiquidityDeposited(lender, amount);
    }

    /**
     * @notice Withdraw principal that was deposited into the pool before in the unit of `poolTokens`
     * @dev Withdrawals are not allowed when 1) the pool withdraw is paused or
     *      2) the LP has not reached lockout period since their last depisit
     *      3) the requested amount is higher than the LP's remaining principal
     * @dev the `amount` is total amount to withdraw. It will deivided by pointsPerShare to get
     *      the number of HDTs to reduct from msg.sender's account.
     * @dev Error checking sequence: 1) is the pool on 2) is the amount right 3)
     */
    function withdraw(uint256 amount) public virtual override {
        poolOn();
        require(
            block.timestamp >=
                lenderInfo[msg.sender].mostRecentLoanTimestamp +
                    withdrawalLockoutPeriod,
            "BasePool:WITHDRAW_TOO_SOON"
        );
        require(
            amount <= lenderInfo[msg.sender].amount,
            "BasePool:WITHDRAW_AMT_TOO_GREAT"
        );

        uint256 amtInPower18 = _toPower18(amount);

        lenderInfo[msg.sender].amount -= amount;

        // Calculate the amount that msg.sender can actually withdraw.
        // withdrawableFundsOf(...) returns everything that msg.sender can claim in terms of
        // number of poolToken, incl. principal,income and losses.
        // then get the portion that msg.sender wants to withdraw (amount / total principal)
        uint256 amountToWithdraw = (withdrawableFundsOf(msg.sender) * amount) /
            balanceOf(msg.sender);

        _burn(msg.sender, amtInPower18);

        //IPoolLocker(poolLocker).transfer(msg.sender, amountToWithdraw);
        PoolLocker(poolLocker).transfer(msg.sender, amountToWithdraw);

        emit LiquidityWithdrawn(msg.sender, amount, amountToWithdraw);
    }

    /**
     * @notice Withdraw all balance from the pool.
     */
    function withdrawAll() external virtual override {
        return withdraw(lenderInfo[msg.sender].amount);
    }

    /********************************************/
    //                Settings                  //
    /********************************************/

    /**
     * @notice Adds an approver to the list who can approve loans.
     * @param approver the approver to be added
     */
    function addCreditApprover(address approver) external virtual override {
        onlyOwnerOrHumaMasterAdmin();
        creditApprovers[approver] = true;
    }

    function setPoolLocker(address _poolLocker)
        external
        virtual
        override
        returns (bool)
    {
        onlyOwnerOrHumaMasterAdmin();
        poolLocker = _poolLocker;

        return true;
    }

    /**
     * @notice Sets the min and max of each loan/credit allowed by the pool.
     */
    function setMinMaxBorrowAmt(uint256 minAmt, uint256 maxAmt)
        external
        virtual
        override
    {
        onlyOwnerOrHumaMasterAdmin();
        require(minAmt > 0, "BasePool:MINAMT_IS_ZERO");
        require(maxAmt >= minAmt, "BasePool:MAXAMIT_LESS_THAN_MINAMT");
        minBorrowAmt = minAmt;
        maxBorrowAmt = maxAmt;
    }

    function setInterestRateBasis(uint256 _interestRateBasis)
        external
        returns (bool)
    {
        onlyOwnerOrHumaMasterAdmin();
        require(_interestRateBasis >= 0);
        interestRateBasis = _interestRateBasis;

        return true;
    }

    function setCollateralRateInBps(uint256 _collateralRequired)
        external
        virtual
        override
    {
        onlyOwnerOrHumaMasterAdmin();
        require(_collateralRequired >= 0);
        collateralRequired = _collateralRequired;
    }

    // Allow borrow applications and loans to be processed by this pool.
    function enablePool() external virtual override {
        onlyOwnerOrHumaMasterAdmin();
        status = PoolStatus.On;
    }

    /**
     * Sets the default grace period for this pool.
     * @param gracePeriod the desired grace period in seconds.
     */
    function setPoolDefaultGracePeriod(uint256 gracePeriod)
        external
        virtual
        override
    {
        onlyOwnerOrHumaMasterAdmin();
        poolDefaultGracePeriod = gracePeriod;
    }

    // Reject all future borrow applications and loans. Note that existing
    // loans will still be processed as expected.
    function disablePool() external virtual override {
        onlyOwnerOrHumaMasterAdmin();
        status = PoolStatus.Off;
    }

    function getWithdrawalLockoutPeriod() public view returns (uint256) {
        return withdrawalLockoutPeriod;
    }

    function setWithdrawalLockoutPeriod(uint256 _withdrawalLockoutPeriod)
        external
        virtual
        override
    {
        onlyOwnerOrHumaMasterAdmin();
        withdrawalLockoutPeriod = _withdrawalLockoutPeriod;
    }

    /**
     * @notice Sets the cap of the pool liquidity.
     */
    function setPoolLiquidityCap(uint256 cap) external virtual override {
        onlyOwnerOrHumaMasterAdmin();
        liquidityCap = cap;
    }

    function setAPR(uint256 _interestRateBasis) external virtual override {
        interestRateBasis = _interestRateBasis;
    }

    function setFees(
        uint256 _platform_fee_flat,
        uint256 _platform_fee_bps,
        uint256 _late_fee_flat,
        uint256 _late_fee_bps,
        uint256 _early_payoff_fee_flat,
        uint256 _early_payoff_fee_bps
    ) public virtual override {
        onlyOwnerOrHumaMasterAdmin();
        require(
            _platform_fee_bps > HumaConfig(humaConfig).treasuryFee(),
            "BasePool:PLATFORM_FEE_BPS_LESS_THAN_PROTOCOL_BPS"
        );
        platform_fee_flat = _platform_fee_flat;
        platform_fee_bps = _platform_fee_bps;
        late_fee_flat = _late_fee_flat;
        late_fee_bps = _late_fee_bps;
        early_payoff_fee_flat = _early_payoff_fee_flat;
        early_payoff_fee_bps = _early_payoff_fee_bps;
    }

    function getLenderInfo(address _lender)
        public
        view
        returns (LenderInfo memory)
    {
        return lenderInfo[_lender];
    }

    function getPoolLiquidity() public view returns (uint256) {
        return poolToken.balanceOf(poolLocker);
    }

    function _toPower18(uint256 amt) internal view returns (uint256) {
        return (amt * POWER18) / (10**poolTokenDecimals);
    }

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}

    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getPoolSummary()
        public
        view
        virtual
        override
        returns (
            address token,
            uint256 apr,
            uint256 minCreditAmt,
            uint256 maxCreditAmt,
            uint256 liquiditycap,
            string memory name,
            string memory symbol,
            uint8 decimals
        )
    {
        ERC20 erc20Contract = ERC20(address(poolToken));
        return (
            address(poolToken),
            interestRateBasis,
            minBorrowAmt,
            maxBorrowAmt,
            liquidityCap,
            erc20Contract.name(),
            erc20Contract.symbol(),
            erc20Contract.decimals()
        );
    }

    /// returns (maxLoanAmt, interest, and the 6 fee fields)
    function getPoolFees()
        public
        view
        virtual
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            interestRateBasis,
            platform_fee_flat,
            platform_fee_bps,
            late_fee_flat,
            late_fee_bps,
            early_payoff_fee_flat,
            early_payoff_fee_bps
        );
    }

    function getPoolLockerAddress() external view returns (address) {
        return poolLocker;
    }

    function getApprovalStatusForBorrower(address borrower)
        external
        view
        returns (bool)
    {
        //return IHumaCredit(creditMapping[borrower]).isApproved();
        // todo
        return true;
    }

    // Allow for sensitive pool functions only to be called by
    // the pool owner and the huma master admin
    function onlyOwnerOrHumaMasterAdmin() internal view {
        require(
            (msg.sender == owner() ||
                msg.sender == HumaConfig(humaConfig).owner()),
            "BasePool:PERMISSION_DENIED_NOT_ADMIN"
        );
    }

    // In order for a pool to issue new loans, it must be turned on by an admin
    // and its custom loan helper must be approved by the Huma team
    function poolOn() internal view {
        require(
            HumaConfig(humaConfig).isProtocolPaused() == false,
            "BasePool:PROTOCOL_PAUSED"
        );
        require(status == PoolStatus.On, "BasePool:POOL_NOT_ON");
    }
}
