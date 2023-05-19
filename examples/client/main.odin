package main

import "core:fmt"

import "../../client"

main :: proc() {
	get()
	post()
}

// basic get request.
get :: proc() {
	res, err := client.get("https://www.google.com/")
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return
	}

	fmt.printf("Status: %s\n", res.status)
	fmt.printf("Headers: %v\n", res.headers)
	fmt.printf("Cookies: %v\n", res.cookies)
	fmt.println(client.response_body(&res))
}

Post_Body :: struct {
	name: string,
	message: string,
}

// POST request with JSON.
post :: proc() {
	req: client.Request
	client.request_init(&req, .Post)

	body := Post_Body{"Laytan", "Hello, World!"}

	if err := client.with_json(&req, body); err != nil {
		fmt.printf("JSON error: %s", err)
		return
	}

	res, err := client.request("https://webhook.site/YOUR-ID-HERE", &req)
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return
	}

	fmt.printf("Status: %s\n", res.status)
	fmt.printf("Headers: %v\n", res.headers)
	fmt.printf("Cookies: %v\n", res.cookies)
	fmt.println(client.response_body(&res))
}
