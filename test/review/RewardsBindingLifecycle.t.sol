// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.36;

import {SRATestBase} from "../SRATestBase.sol";
import {Binding} from "../../src/lib/SraTypes.sol";

contract RewardsBindingLifecycleReview is SRATestBase {
    function test_BindingMovesBetweenOrchestratorsWithoutRegistryApproval() public {
        address a = makeAddr("binding-a");
        address b = makeAddr("binding-b");
        address payer = makeAddr("binding-payer");
        address operator = makeAddr("binding-operator");
        _admit(a, a);
        _admit(b, b);

        Binding[] memory pairs = new Binding[](1);
        pairs[0] = Binding({payer: payer, operator: operator});
        _registerPairsAs(a, pairs);

        vm.prank(a);
        sra.cancelBinding(payer, operator);
        _registerPairsAs(b, pairs);

        assertEq(sra.bindingOf(payer, operator), b);
    }
}
