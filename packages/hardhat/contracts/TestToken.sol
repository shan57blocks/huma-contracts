//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    uint256 constant _initial_supply = 100000 * (10**18);

    constructor() ERC20("TestToken", "TT") {
        _mint(msg.sender, 1000);
    }

    function give1000To(address _to) external {
        _mint(_to, 1000);
    }

    function mint(address _to, uint256 amount) external {
        _mint(_to, amount);
    }

    function burn(address _from, uint256 amount) external {
        _burn(_from, amount);
    }
}
