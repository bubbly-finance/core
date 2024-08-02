// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;
pragma abicoder v2;
import './pool/IBubblyPoolImmutables.sol';
import './pool/IBubblyPoolState.sol';
import './pool/IBubblyPoolDerivedState.sol';
import './pool/IBubblyPoolActions.sol';
import './pool/IBubblyPoolOwnerActions.sol';
import './pool/IBubblyPoolEvents.sol';

/// @title The interface for a Bubbly Pool
/// @notice A Bubbly pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IBubblyPool is
    IBubblyPoolImmutables,
    IBubblyPoolState,
    IBubblyPoolActions,
    IBubblyPoolOwnerActions,
    IBubblyPoolEvents
{

}
