//SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import "./interfaces/ICredit.sol";
import {BaseStructs as BS} from "./libraries/BaseStructs.sol";

import "./BaseFeeManager.sol";
import "./BasePool.sol";

import "hardhat/console.sol";

contract BaseCreditPool is ICredit, BasePool {
    // Divider to get monthly interest rate from APR BPS. 10000 * 12
    uint256 public constant BPS_DIVIDER = 120000;
    uint256 public constant HUNDRED_PERCENT_IN_BPS = 10000;

    using SafeERC20 for IERC20;
    using ERC165Checker for address;
    using BS for BaseCreditPool;

    // mapping from wallet address to the credit record
    mapping(address => BS.CreditRecord) public creditRecordMapping;
    // mapping from wallet address to the collateral supplied by this wallet
    mapping(address => BS.CollateralInfo) internal collateralInfoMapping;

    constructor(
        address _poolToken,
        address _humaConfig,
        address _poolLockerAddress,
        address _feeManagerAddress,
        string memory _poolName,
        string memory _hdtName,
        string memory _hdtSymbol
    )
        BasePool(
            _poolToken,
            _humaConfig,
            _poolLockerAddress,
            _feeManagerAddress,
            _poolName,
            _hdtName,
            _hdtSymbol
        )
    {}

    /**
     * @notice accepts a credit request from msg.sender
     */
    function requestCredit(
        uint256 _creditLimit,
        uint256 _paymentIntervalInDays,
        uint256 _numOfPayments
    ) external virtual override {
        // Open access to the borrower
        // Parameter and condition validation happens in initiate()
        initiate(
            msg.sender,
            _creditLimit,
            address(0),
            0,
            0,
            poolAprInBps,
            payScheduleOption,
            _paymentIntervalInDays,
            _numOfPayments
        );
    }

    /**
     * @notice initiation of a credit
     * @param _borrower the address of the borrower
     * @param _creditLimit the amount of the liquidity asset that the borrower obtains
     * @param _collateralAsset the address of the collateral asset.
     * @param _collateralAmount the amount of the collateral asset
     */
    function initiate(
        address _borrower,
        uint256 _creditLimit,
        address _collateralAsset,
        uint256 _collateralParam,
        uint256 _collateralAmount,
        uint256 _aprInBps,
        BS.PayScheduleOptions _payScheduleOption,
        uint256 _paymentIntervalInDays,
        uint256 _remainingPayments
    ) internal virtual {
        protocolAndpoolOn();
        // Borrowers cannot have two credit lines in one pool. They can request to increase line.
        // todo add a test for this check
        require(
            creditRecordMapping[msg.sender].state == BS.CreditState.Deleted,
            "CREDIT_LINE_ALREADY_EXIST"
        );

        // Borrowing amount needs to be lower than max for the pool.
        require(maxBorrowAmount >= _creditLimit, "GREATER_THAN_LIMIT");

        // Populates basic credit info fields
        BS.CreditRecord memory cr;
        cr.creditLimit = uint96(_creditLimit);
        // note, leaving balance at the default 0, update balance only after drawdown
        cr.aprInBps = uint16(_aprInBps);
        cr.option = _payScheduleOption;
        cr.paymentIntervalInDays = uint16(_paymentIntervalInDays);
        cr.remainingPayments = uint16(_remainingPayments);
        cr.state = BS.CreditState.Requested;
        creditRecordMapping[_borrower] = cr;

        // Populates fields related to collateral
        if (_collateralAsset != address(0)) {
            BS.CollateralInfo memory ci;
            ci.collateralAsset = _collateralAsset;
            ci.collateralParam = _collateralParam;
            ci.collateralAmount = uint88(_collateralAmount);
            collateralInfoMapping[_borrower] = ci;
        }
    }

    /**
     * Approves the credit request with the terms on record.
     */
    function approveCredit(address _borrower) public virtual override {
        protocolAndpoolOn();
        onlyApprovers();
        // question shall we check to make sure the credit limit is lowered than the allowed max
        creditRecordMapping[_borrower].state = BS.CreditState.Approved;
    }

    function invalidateApprovedCredit(address _borrower)
        public
        virtual
        override
    {
        protocolAndpoolOn();
        onlyApprovers();
        creditRecordMapping[_borrower].state = BS.CreditState.Deleted;
    }

    function isApproved(address _borrower)
        public
        view
        virtual
        override
        returns (bool)
    {
        if ((creditRecordMapping[_borrower].state >= BS.CreditState.Approved))
            return true;
        else return false;
    }

    function drawdown(uint256 borrowAmount) external virtual override {
        // Open access to the borrower
        // Condition validation happens in drawdownWithCollateral()
        return
            drawdownWithCollateral(msg.sender, borrowAmount, address(0), 0, 0);
    }

    function drawdownWithCollateral(
        address _borrower,
        uint256 _borrowAmount,
        address _collateralAsset,
        uint256 _collateralParam,
        uint256 _collateralCount
    ) public virtual override {
        protocolAndpoolOn();

        // msg.sender needs to be the borrower themselvers or the approver.
        if (msg.sender != _borrower) onlyApprovers();

        // Borrowing amount needs to be higher than min for the pool.
        // todo 8/23 need to move some tests from requestCredit() to drawdown()
        require(_borrowAmount >= minBorrowAmount, "SMALLER_THAN_LIMIT");

        require(isApproved(_borrower), "CREDIT_NOT_APPROVED");

        BS.CreditRecord memory cr = creditRecordMapping[_borrower];
        // todo 8/23 add a test for this check
        require(
            _borrowAmount <= cr.creditLimit - cr.balance,
            "EXCEEDED_CREDIT_LMIIT"
        );
        // todo 8/23 add a check to make sure the account is in good standing.
        cr.balance = uint96(uint256(cr.balance) + _borrowAmount);

        // // Calculates next payment amount and due date
        cr.dueDate = uint64(
            block.timestamp +
                uint256(cr.paymentIntervalInDays) *
                SECONDS_IN_A_DAY
        );

        // Set the monthly payment (except the final payment, hook for installment case
        cr.dueAmount = uint96(
            IFeeManager(feeManagerAddress).getRecurringPayment(cr)
        );
        creditRecordMapping[_borrower] = cr;

        (
            uint256 amtToBorrower,
            uint256 protocolFee,
            uint256 poolIncome
        ) = IFeeManager(feeManagerAddress).distBorrowingAmount(
                _borrowAmount,
                humaConfig
            );

        if (poolIncome > 0) distributeIncome(poolIncome);

        // Record the collateral info.
        if (_collateralAsset != address(0)) {
            BS.CollateralInfo memory ci = collateralInfoMapping[_borrower];
            if (ci.collateralAsset != address(0)) {
                require(
                    _collateralAsset == ci.collateralAsset,
                    "COLLATERAL_MISMATCH"
                );
            }
            // todo check to make sure the collateral amount meets the requirements
            ci.collateralAmount = uint88(_collateralCount);
            ci.collateralParam = _collateralParam;
            collateralInfoMapping[_borrower] = ci;
        }

        // // Transfers collateral asset
        if (_collateralAsset != address(0)) {
            if (_collateralAsset.supportsInterface(type(IERC721).interfaceId)) {
                IERC721(_collateralAsset).safeTransferFrom(
                    _borrower,
                    poolLockerAddress,
                    _collateralParam
                );
            } else if (
                _collateralAsset.supportsInterface(type(IERC20).interfaceId)
            ) {
                IERC20(_collateralAsset).safeTransferFrom(
                    msg.sender,
                    poolLockerAddress,
                    _collateralCount
                );
            } else {
                revert("COLLATERAL_ASSET_NOT_SUPPORTED");
            }
        }

        // Transfer protocole fee and funds the _borrower
        address treasuryAddress = HumaConfig(humaConfig).humaTreasury();
        PoolLocker locker = PoolLocker(poolLockerAddress);
        locker.transfer(treasuryAddress, protocolFee);
        locker.transfer(_borrower, amtToBorrower);
    }

    /**
     * @notice Borrower makes one payment. If this is the final payment,
     * it automatically triggers the payoff process.
     * @dev "WRONG_ASSET" reverted when asset address does not match
     * @dev "AMOUNT_TOO_LOW" reverted when the asset is short of the scheduled payment and fees
     */
    function makePayment(address _asset, uint256 _amount)
        external
        virtual
        override
    {
        protocolAndpoolOn();

        BS.CreditRecord memory cr = creditRecordMapping[msg.sender];

        require(_asset == address(poolToken), "WRONG_ASSET");
        require(_amount > 0, "CANNOT_BE_ZERO_AMOUNT");
        // todo 8/23 check to see if this condition is still needed
        require(cr.remainingPayments > 0, "LOAN_PAID_OFF_ALREADY");

        uint256 principal;
        uint256 interest;
        uint256 fees;
        bool isLate;
        bool goodPay;
        bool paidOff;

        (principal, interest, fees, isLate, goodPay, paidOff) = IFeeManager(
            feeManagerAddress
        ).getNextPayment(cr, 0, _amount);

        if (paidOff) {
            cr.dueAmount = 0;
            cr.dueDate = 0;
            cr.balance = 0;
            cr.remainingPayments = 0;
            cr.state = BS.CreditState.Deleted;
        } else {
            cr.balance = uint96(cr.balance - principal);
            cr.remainingPayments -= 1;
            cr.dueDate =
                cr.dueDate +
                uint64(cr.paymentIntervalInDays * SECONDS_IN_A_DAY);
            if (cr.remainingPayments == 1) {
                if (cr.option == BS.PayScheduleOptions.InterestOnly)
                    cr.dueAmount += cr.balance;
                else {
                    cr.dueAmount = cr.balance * (1 + cr.aprInBps / 120000);
                }
            }
        }
        creditRecordMapping[msg.sender] = cr;

        // Distribute income
        // todo 8/23 need to apply logic for protocol fee
        uint256 poolIncome = interest + fees;
        distributeIncome(poolIncome);

        uint256 amountToCollect = principal + interest + fees;

        // when _amount is more than what is needed to pay off, we only collect payoff amount
        if (amountToCollect > 0) {
            // Transfer assets from the _borrower to pool locker
            IERC20 token = IERC20(poolToken);
            token.transferFrom(msg.sender, poolLockerAddress, amountToCollect);
        }
    }

    /**
     * @notice Borrower requests to payoff the credit
     */
    function payoff(
        address borrower,
        address asset,
        uint256 amount
    ) external virtual override {
        //todo to implement
    }

    /**
     * @notice Triggers the default process
     * @return losses the amount of remaining losses to the pool after collateral
     * liquidation, pool cover, and staking.
     */
    function triggerDefault(address borrower)
        external
        virtual
        override
        returns (uint256 losses)
    {
        protocolAndpoolOn();

        // check to make sure the default grace period has passed.
        require(
            block.timestamp >
                creditRecordMapping[borrower].dueDate +
                    poolDefaultGracePeriodInSeconds,
            "DEFAULT_TRIGGERED_TOO_EARLY"
        );

        // FeatureRequest: add pool cover logic

        // FeatureRequest: add staking logic

        // Trigger loss process
        losses = creditRecordMapping[borrower].balance;
        distributeLosses(losses);

        return losses;
    }

    /**
     * @notice Gets high-level information about the loan.
     */
    function getCreditInformation(address borrower)
        external
        view
        returns (
            uint96 creditLimit,
            uint96 dueAmount,
            uint64 paymentIntervalInDays,
            uint16 aprInBps,
            uint64 dueDate,
            uint96 balance,
            uint16 remainingPayments,
            BS.CreditState state
        )
    {
        BS.CreditRecord memory cr = creditRecordMapping[borrower];
        return (
            cr.creditLimit,
            cr.dueAmount,
            cr.paymentIntervalInDays,
            cr.aprInBps,
            cr.dueDate,
            cr.balance,
            cr.remainingPayments,
            cr.state
        );
    }

    function getApprovalStatusForBorrower(address borrower)
        external
        view
        returns (bool)
    {
        return creditRecordMapping[borrower].state >= BS.CreditState.Approved;
    }

    function onlyApprovers() internal view {
        require(creditApprovers[msg.sender] == true, "APPROVER_REQUIRED");
    }
}
