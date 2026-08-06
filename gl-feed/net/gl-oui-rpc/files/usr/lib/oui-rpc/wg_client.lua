local wg_client = dofile("/usr/lib/oui-rpc/wg-client.lua")

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
}
