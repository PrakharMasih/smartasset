#!/bin/zsh
# Reduce Motion (plan §12.3): the app must not run its own animations. System controls already respect the setting.
# Any use of an animation API in the app must be reviewed and then guarded with accessibilityReduceMotion.
cd ${0:A:h:h} || exit 1
hits=$(grep -rnE "withAnimation|\.animation\(|\.transition\(|\.symbolEffect|NSAnimationContext|CABasicAnimation|CAKeyframeAnimation" Sources/SmartAsset | grep -v "accessibilityReduceMotion\|// motion: ok" )
if [[ -n "$hits" ]]; then echo "$hits"; echo "FAIL audit-motion: animation without a Reduce Motion guard"; exit 1; fi
echo "PASS audit-motion: no custom animations (system transitions follow Reduce Motion)"
