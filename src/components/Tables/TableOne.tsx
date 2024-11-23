import { CONNECTION } from "@/types/connection";
import Image from "next/image";

const connectionList: CONNECTION[] = [
  {
    logo: "/images/brand/brand-01.svg",
    name: "Google",
    events: 3.5,
    updatedEvents: "768",
    authStatus: 590,
    conversion: 48,
  },
  {
    logo: "/images/brand/brand-02.svg",
    name: "Twitter",
    events: 2.2,
    updatedEvents: "635",
    authStatus: 467,
    conversion: 43,
  },
  {
    logo: "/images/brand/brand-03.svg",
    name: "Github",
    events: 2.1,
    updatedEvents: "290",
    authStatus: 420,
    conversion: 37,
  },
  {
    logo: "/images/brand/brand-04.svg",
    name: "Vimeo",
    events: 1.5,
    updatedEvents: "580",
    authStatus: 389,
    conversion: 25,
  },
  {
    logo: "/images/brand/brand-05.svg",
    name: "Facebook",
    events: 3.5,
    updatedEvents: "768",
    authStatus: 390,
    conversion: 8,
  },
];

const TableOne = () => {
  return (
    <div className="rounded-sm border border-stroke bg-white px-5 pb-2.5 pt-6 shadow-default dark:border-strokedark dark:bg-boxdark sm:px-7.5 xl:pb-1">
      <h4 className="mb-6 text-xl font-semibold text-black dark:text-white">
        Data Connections
      </h4>

      <div className="flex flex-col">
        <div className="grid grid-cols-3 rounded-sm bg-gray-2 dark:bg-meta-4 sm:grid-cols-5">
          <div className="p-2.5 xl:p-5">
            <h5 className="text-sm font-medium uppercase xsm:text-base">
              Source
            </h5>
          </div>
          <div className="p-2.5 text-center xl:p-5">
            <h5 className="text-sm font-medium uppercase xsm:text-base">
              Events
            </h5>
          </div>
          <div className="p-2.5 text-center xl:p-5">
            <h5 className="text-sm font-medium uppercase xsm:text-base">
              Updated Events
            </h5>
          </div>
          <div className="hidden p-2.5 text-center sm:block xl:p-5">
            <h5 className="text-sm font-medium uppercase xsm:text-base">
              Authorization
            </h5>
          </div>
          <div className="hidden p-2.5 text-center sm:block xl:p-5">
            <h5 className="text-sm font-medium uppercase xsm:text-base">
              Progress
            </h5>
          </div>
        </div>

        {connectionList.map((brand, key) => (
          <div
            className={`grid grid-cols-3 sm:grid-cols-5 ${
              key === connectionList.length - 1
                ? ""
                : "border-b border-stroke dark:border-strokedark"
            }`}
            key={key}
          >
            <div className="flex items-center gap-3 p-2.5 xl:p-5">
              <div className="flex-shrink-0">
                <Image src={brand.logo} alt="Brand" width={48} height={48} />
              </div>
              <p className="hidden text-black dark:text-white sm:block">
                {brand.name}
              </p>
            </div>

            <div className="flex items-center justify-center p-2.5 xl:p-5">
              <p className="text-black dark:text-white">{brand.events}K</p>
            </div>

            <div className="flex items-center justify-center p-2.5 xl:p-5">
              <p className="text-meta-3">{brand.updatedEvents}</p>
            </div>

            <div className="hidden items-center justify-center p-2.5 sm:flex xl:p-5">
              {/* <p className="text-black dark:text-white">{brand.authStatus}</p> */}
              <button
                      className="flex justify-center rounded bg-primary px-6 py-2 font-medium text-gray hover:bg-opacity-90"
                      type="submit"
                    >
                      Connect
                    </button>
            </div>

            <div className="hidden items-center justify-center p-2.5 sm:flex xl:p-5">
              <p className="text-meta-5">{brand.conversion}%</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default TableOne;
