-- GL SDK4 underscore-named WireGuard client object. This exists alongside the
-- hyphenated "wg-client" purely because the frontend splits its calls between
-- the two: the manual/custom config path uses "wg-client", while the
-- commercial-provider (NordVPN/Mullvad/ExpressVPN/...) path uses "wg_client".
--
-- This port reports every group as CUSTOM (group_type=2), so none of the
-- provider screens are reachable through normal navigation. They are stubbed
-- anyway rather than left to fall through to the dispatcher's
-- "no such method" error, because a few of them (get_max_client in
-- particular) are called from code paths with no .catch handler - a rejected
-- call there leaves the UI stuck on a loading spinner instead of failing
-- visibly. The stubs return empty/unsupported results in the shape the
-- frontend destructures, so those screens degrade to "no providers" rather
-- than hanging.

local wg_client = dofile("/usr/lib/oui-rpc/wg-client.lua")
local cjson = require "cjson"

local function unsupported()
	return { err_code = 1, err_msg = "third-party VPN providers are not supported on this build" }
end

return {
	gen_key = function(args)
		if args and args.private_key then
			local result = wg_client.generate_publickey(args)
			if result.err_code then return result end
			result.private_key = args.private_key
			return result
		end
		return wg_client.generate_key()
	end,

	get_max_client = function()
		return { max_client = 0 }
	end,

	get_provider_user_info = function()
		return { allocated = 0, available = 0, expires_at = 0 }
	end,

	create_provider_account = unsupported,
	update_provider_config = unsupported,
	submit_provider_otp = unsupported,

	expressvpn_check_eligibility = unsupported,
	expressvpn_get_status = unsupported,
	expressvpn_get_subscriptions = unsupported,
	expressvpn_request_checkout = unsupported,
	expressvpn_start_login = unsupported,
}
