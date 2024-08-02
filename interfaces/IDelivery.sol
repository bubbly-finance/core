// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title Delivery Interface

interface IDelivery {
    /// @notice Returns the amount out received for a given exact input swap without executing the swap
    /// @param pool Pool address 
    /// @param amount Vtoken amount desired to deliver
    /// @param forY deliver direction
    /// @return amountIn Actual delivered vtoken quantity
    function Deliver(address pool, uint256 amount, bool forY) external returns (uint256 amountIn);

    /// @notice Set the mapping relationship between token with mock token
    /// @param token The token being swapped in
    /// @param vtoken The token being swapped out
    function setToken(
        address token,
        address vtoken
    ) external ;

}
