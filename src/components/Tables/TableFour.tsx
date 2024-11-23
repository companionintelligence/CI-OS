import { CONNECTION } from "@/types/connection";
import Image from "next/image";
import DropdownDefault from "../Dropdowns/DropdownDefault";

const connectionList: CONNECTION[] = [
  {
    logo: "/images/brand/brand-01.svg",
    name: "Google",
    events: 3.5,
    updatedEvents: "5,768",
    authStatus: 590,
    conversion: 4.8,
  },
  {
    logo: "/images/brand/brand-02.svg",
    name: "Twitter",
    events: 2.2,
    updatedEvents: "4,635",
    authStatus: 467,
    conversion: 4.3,
  },
  {
    logo: "/images/brand/brand-06.svg",
    name: "Youtube",
    events: 2.1,
    updatedEvents: "4,290",
    authStatus: 420,
    conversion: 3.7,
  },
  {
    logo: "/images/brand/brand-04.svg",
    name: "Vimeo",
    events: 1.5,
    updatedEvents: "3,580",
    authStatus: 389,
    conversion: 2.5,
  },
  {
    logo: "/images/brand/brand-05.svg",
    name: "Facebook",
    events: 3.5,
    updatedEvents: "6,768",
    authStatus: 390,
    conversion: 4.2,
  },
];

const TableFour: React.FC = () => {
  return (
    <div className="col-span-12 xl:col-span-7">
      <div className="rounded-sm border border-stroke bg-white px-5 pb-2.5 pt-6 shadow-default dark:border-strokedark dark:bg-boxdark sm:px-7.5 xl:pb-1">
        <div className="mb-6 flex justify-between">
          <div>
            <h4 className="text-title-sm2 font-bold text-black dark:text-white">
              Top Channels
            </h4>
          </div>
          <DropdownDefault />
        </div>

        <div className="flex flex-col">
          <div className="grid grid-cols-3 rounded-sm bg-gray-2 dark:bg-meta-4 sm:grid-cols-4">
            <div className="p-2.5 xl:p-4">
              <h5 className="text-sm font-medium uppercase xsm:text-base">
                Source
              </h5>
            </div>
            <div className="p-2.5 text-center xl:p-4">
              <h5 className="text-sm font-medium uppercase xsm:text-base">
                events
              </h5>
            </div>
            <div className="p-2.5 text-center xl:p-4">
              <h5 className="text-sm font-medium uppercase xsm:text-base">
                Updated Events
              </h5>
            </div>
            <div className="hidden p-2.5 text-center sm:block xl:p-4">
              <h5 className="text-sm font-medium uppercase xsm:text-base">
                Conversion
              </h5>
            </div>
          </div>

          {connectionList.map((connection, key) => (
            <div
              className={`grid grid-cols-3 sm:grid-cols-4 ${
                key === connectionList.length - 1
                  ? ""
                  : "border-b border-stroke dark:border-strokedark"
              }`}
              key={key}
            >
              <div className="flex items-center gap-3 p-2.5 xl:p-5">
                <div className="h-9 w-full max-w-9 flex-shrink-0">
                  <Image src={connection.logo} width={60} height={50} alt="Connection" />
                </div>
                <p className="hidden font-medium text-black dark:text-white sm:block">
                  {connection.name}
                </p>
              </div>

              <div className="flex items-center justify-center p-2.5 xl:p-5">
                <p className="font-medium text-black dark:text-white">{connection.events}K</p>
              </div>

              <div className="flex items-center justify-center p-2.5 xl:p-5">
                <p className="font-medium text-meta-3">{connection.updatedEvents}</p>
              </div>

              <div className="hidden items-center justify-center p-2.5 sm:flex xl:p-5">
                <p className="font-medium text-meta-5">{connection.conversion}%</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

export default TableFour;
