export interface Request {
    body?: any;
    params?: { [key: string]: string };
    query?: { [key: string]: string };
}

export interface Response {
    status: (code: number) => Response;
    json: (data: any) => void;
    send: (data: any) => void;
}